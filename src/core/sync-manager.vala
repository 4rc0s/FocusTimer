/*
 * Copyright (c) 2026 focus-timer contributors
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

using GLib;


namespace Ft
{
    /**
     * Syncs stats between devices through a shared folder, such as a Syncthing folder.
     *
     * Design:
     *
     *  - Each device appends records only to its own file, `<device-id>.jsonl`. A file
     *    never has more than one writer, so the sync tool never has to resolve conflicts.
     *
     *  - A record is a full snapshot of the stats entries derived from one source
     *    (a time-block or a gap). Entries can be revised while a time-block is running,
     *    so a source may be written several times; the last record for a source wins.
     *    A record with `"deleted": true` removes the source.
     *
     *  - Imported entries go into the regular `stats` table, so the existing triggers keep
     *    `aggregatedstats` correct and the stats views work unchanged. They are marked with
     *    a negative `source-id` derived from the remote device id and source key. Local
     *    entries always have a non-negative `source-id`, so imported entries never collide
     *    with local ones and are never exported again.
     *
     *  - Only the `stats` table is synced. Sessions, time-blocks and gaps drive the timer
     *    itself and stay local.
     *
     * The device's own file is the record of what has been exported, and imports are
     * idempotent, so no extra bookkeeping is stored. On start, everything is reconciled:
     * local changes made while sync was off get exported, and remote files are re-read.
     */
    [SingleInstance]
    public sealed class SyncManager : GLib.Object
    {
        private const int    FORMAT_VERSION = 1;
        private const string FILE_EXTENSION = ".jsonl";
        private const string DEVICE_ID_FILE_NAME = "sync-device-id";
        private const uint   EXPORT_DELAY = 2;    // seconds
        private const uint   IMPORT_DELAY = 3;    // seconds
        private const uint   POLL_INTERVAL = 300;  // seconds; fallback when file monitoring is unavailable

        /**
         * Whether sync is enabled and a folder is configured.
         */
        public bool active { get; private set; default = false; }

        /**
         * Human-readable status, displayed in preferences.
         */
        public string status { get; private set; default = ""; }

        private class Snapshot
        {
            public string        device;
            public string        source;
            public string        category;
            public bool          deleted;
            public Ft.StatsEntry[] entries;
        }

        private GLib.Settings?                         settings = null;
        private Ft.StatsManager?                       stats_manager = null;
        private string?                                device_id = null;
        private GLib.File?                             folder = null;
        private GLib.FileMonitor?                      monitor = null;
        private GLib.HashTable<string, string>         exported;     // local source key -> digest
        private GLib.HashTable<string, Ft.StatsEntry>  pending;      // local source key -> entry
        private GLib.HashTable<string, int64?>         offsets;      // file name -> bytes consumed
        private GLib.HashTable<string, string>?        imported = null;  // source-id -> digest
        private GLib.GenericSet<string>                remote_devices;
        private bool                                   export_all = false;
        private bool                                   import_all = false;
        private bool                                   is_running = false;
        private bool                                   run_again = false;
        private uint                                   export_timeout_id = 0;
        private uint                                   import_timeout_id = 0;
        private uint                                   poll_timeout_id = 0;
        private string?                                last_error = null;
        private GLib.DateTime?                         last_sync_time = null;
        private Ft.AsyncCallback[]                     idle_callbacks;

        construct
        {
            this.exported       = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
            this.pending        = new GLib.HashTable<string, Ft.StatsEntry> (GLib.str_hash, GLib.str_equal);
            this.offsets        = new GLib.HashTable<string, int64?> (GLib.str_hash, GLib.str_equal);
            this.remote_devices = new GLib.GenericSet<string> (GLib.str_hash, GLib.str_equal);
            this.idle_callbacks = {};

            this.settings = Ft.get_settings ();
            this.settings.changed.connect (this.on_settings_changed);

            this.stats_manager = new Ft.StatsManager ();
            this.stats_manager.entry_saved.connect (this.on_entry_changed);
            this.stats_manager.entry_deleted.connect (this.on_entry_changed);

            this.reconfigure ();
        }

        /*
         * Keys and digests
         */

        /**
         * Key identifying the source of a local entry within this device.
         */
        private static string get_local_source_key (Ft.StatsEntry entry)
        {
            return entry.source_id != 0
                    ? @"$(entry.category):$(entry.source_id)"
                    : @"$(entry.category):t$(entry.time)";
        }

        /**
         * Map a remote source to a stable negative `source-id`.
         *
         * Uses the first 62 bits of a SHA-256 digest, so collisions are negligible.
         */
        private static int64 get_imported_source_id (string device,
                                                     string source)
        {
            var checksum = new GLib.Checksum (GLib.ChecksumType.SHA256);
            var key = @"$(device)/$(source)";
            checksum.update (key.data, key.length);

            var buffer = new uint8[32];
            size_t length = buffer.length;
            checksum.get_digest (buffer, ref length);

            int64 value = 0;

            for (var index = 0; index < 8; index++) {
                value = (value << 8) | buffer[index];
            }

            value &= 0x3FFFFFFFFFFFFFFF;

            return -1 - value;
        }

        private static int compare_entries (Ft.StatsEntry a,
                                            Ft.StatsEntry b)
        {
            return a.time < b.time ? -1 : (a.time > b.time ? 1 : 0);
        }

        /**
         * Canonical representation of a set of entries, used to detect changes.
         */
        private static string compute_digest (Ft.StatsEntry[] entries)
        {
            var sorted = new GLib.GenericArray<Ft.StatsEntry> ();

            foreach (var entry in entries) {
                sorted.add (entry);
            }

            sorted.sort (compare_entries);

            var builder = new GLib.StringBuilder ();

            sorted.foreach (
                (entry) => {
                    builder.append_printf ("%s,%s,%s,%s;",
                                           entry.time.to_string (),
                                           entry.date,
                                           entry.offset.to_string (),
                                           entry.duration.to_string ());
                });

            return builder.str;
        }

        /*
         * Files
         */

        private static string get_data_directory ()
        {
            return GLib.Path.build_filename (GLib.Environment.get_user_data_dir (),
                                             Config.PACKAGE_NAME);
        }

        /**
         * Device identity is stored next to the database rather than in GSettings, so that
         * syncing dconf settings between machines does not make two devices share an id.
         */
        private static string load_or_create_device_id () throws GLib.Error
        {
            var directory = GLib.File.new_for_path (get_data_directory ());
            var file      = directory.get_child (DEVICE_ID_FILE_NAME);

            if (file.query_exists ())
            {
                uint8[] contents;
                file.load_contents (null, out contents, null);

                var device_id = ((string) contents).strip ();

                if (GLib.Uuid.string_is_valid (device_id)) {
                    return device_id;
                }

                GLib.warning ("Invalid sync device id, generating a new one");
            }

            if (!directory.query_exists ()) {
                directory.make_directory_with_parents ();
            }

            var device_id = GLib.Uuid.string_random ();

            file.replace_contents (device_id.data,
                                   null,
                                   false,
                                   GLib.FileCreateFlags.PRIVATE,
                                   null);

            return device_id;
        }

        private static bool is_device_file (string name)
        {
            return name.has_suffix (FILE_EXTENSION) &&
                   !name.has_prefix (".") &&
                   !name.contains (".sync-conflict-") &&
                   !name.contains ("~");
        }

        private static GLib.File get_own_file (GLib.File folder,
                                               string    device_id)
        {
            return folder.get_child (device_id + FILE_EXTENSION);
        }

        /*
         * Serialization
         */

        private static string serialize_snapshot (string          device_id,
                                                  string          source,
                                                  string          category,
                                                  Ft.StatsEntry[] entries,
                                                  bool            deleted)
        {
            var builder = new Json.Builder ();

            builder.begin_object ();
            builder.set_member_name ("v");
            builder.add_int_value (FORMAT_VERSION);
            builder.set_member_name ("device");
            builder.add_string_value (device_id);
            builder.set_member_name ("source");
            builder.add_string_value (source);
            builder.set_member_name ("category");
            builder.add_string_value (category);
            builder.set_member_name ("updated");
            builder.add_int_value (Ft.Timestamp.from_now ());

            if (deleted) {
                builder.set_member_name ("deleted");
                builder.add_boolean_value (true);
            }

            builder.set_member_name ("entries");
            builder.begin_array ();

            foreach (var entry in entries)
            {
                builder.begin_array ();
                builder.add_int_value (entry.time);
                builder.add_string_value (entry.date);
                builder.add_int_value (entry.offset);
                builder.add_int_value (entry.duration);
                builder.end_array ();
            }

            builder.end_array ();
            builder.end_object ();

            var generator = new Json.Generator ();
            generator.pretty = false;
            generator.set_root (builder.get_root ());

            return generator.to_data (null);
        }

        private static Snapshot? parse_snapshot (string line)
        {
            var parser = new Json.Parser ();

            try {
                parser.load_from_data (line, -1);
            }
            catch (GLib.Error error) {
                GLib.warning ("Skipping malformed sync record: %s", error.message);
                return null;
            }

            var root = parser.get_root ();

            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return null;
            }

            var object = root.get_object ();

            if (object.get_int_member_with_default ("v", 0) != FORMAT_VERSION) {
                return null;  // unknown format, possibly written by a newer version
            }

            var snapshot = new Snapshot ();
            snapshot.device   = object.get_string_member_with_default ("device", "");
            snapshot.source   = object.get_string_member_with_default ("source", "");
            snapshot.category = object.get_string_member_with_default ("category", "");
            snapshot.deleted  = object.get_boolean_member_with_default ("deleted", false);
            snapshot.entries  = {};

            if (snapshot.device == "" || snapshot.source == "" || snapshot.category == "") {
                return null;
            }

            if (snapshot.deleted || !object.has_member ("entries")) {
                return snapshot;
            }

            var array = object.get_array_member ("entries");

            for (var index = 0U; index < array.get_length (); index++)
            {
                var item = array.get_array_element (index);

                if (item == null ||
                    item.get_length () != 4 ||
                    item.get_element (0).get_value_type () != typeof (int64) ||
                    item.get_element (1).get_value_type () != typeof (string) ||
                    item.get_element (2).get_value_type () != typeof (int64) ||
                    item.get_element (3).get_value_type () != typeof (int64))
                {
                    return null;
                }

                var entry = new Ft.StatsEntry ();
                entry.category = snapshot.category;
                entry.time     = item.get_int_element (0);
                entry.date     = item.get_string_element (1);
                entry.offset   = item.get_int_element (2);
                entry.duration = item.get_int_element (3);

                if (entry.duration <= 0 ||
                    entry.date == null ||
                    !Ft.Database.parse_date (entry.date).valid ())
                {
                    return null;
                }

                snapshot.entries += entry;
            }

            return snapshot;
        }

        /*
         * Database
         */

        private async Ft.StatsEntry[] fetch_entries (Gom.Filter? filter) throws GLib.Error
        {
            Ft.StatsEntry[] entries = {};

            var repository = Ft.Database.get_repository ();

            if (repository == null) {
                return entries;
            }

            var group = yield repository.find_async (typeof (Ft.StatsEntry), filter);

            if (group.count > 0) {
                yield group.fetch_async (0U, group.count);
            }

            for (var index = 0U; index < group.count; index++) {
                entries += (Ft.StatsEntry) group.get_index (index);
            }

            return entries;
        }

        private enum Comparison
        {
            EQUAL,
            LESS_THAN,
            GREATER_OR_EQUAL
        }

        private static Gom.Filter create_int64_filter (string     property_name,
                                                       int64      value,
                                                       Comparison comparison = Comparison.EQUAL)
        {
            var gvalue = GLib.Value (typeof (int64));
            gvalue.set_int64 (value);

            switch (comparison)
            {
                case Comparison.LESS_THAN:
                    return new Gom.Filter.lt (typeof (Ft.StatsEntry), property_name, gvalue);

                case Comparison.GREATER_OR_EQUAL:
                    return new Gom.Filter.gte (typeof (Ft.StatsEntry), property_name, gvalue);

                default:
                    return new Gom.Filter.eq (typeof (Ft.StatsEntry), property_name, gvalue);
            }
        }

        private static Gom.Filter create_string_filter (string property_name,
                                                        string value)
        {
            var gvalue = GLib.Value (typeof (string));
            gvalue.set_string (value);

            return new Gom.Filter.eq (typeof (Ft.StatsEntry), property_name, gvalue);
        }

        private async Ft.StatsEntry[] fetch_local_source (Ft.StatsEntry sample) throws GLib.Error
        {
            var filter = new Gom.Filter.and (
                    create_string_filter ("category", sample.category),
                    sample.source_id != 0
                        ? create_int64_filter ("source-id", sample.source_id)
                        : new Gom.Filter.and (create_int64_filter ("source-id", 0),
                                              create_int64_filter ("time", sample.time)));

            return yield this.fetch_entries (filter);
        }

        private async void apply_snapshot (Snapshot snapshot,
                                           int64    source_id) throws GLib.Error
        {
            var repository = Ft.Database.get_repository ();

            if (repository == null) {
                return;
            }

            var existing = yield this.fetch_entries (
                    create_int64_filter ("source-id", source_id));

            // Delete existing entries first, so the `aggregatedstats` triggers recount correctly
            if (existing.length > 0)
            {
                var to_delete = (Gom.ResourceGroup) GLib.Object.@new (
                        typeof (Gom.ResourceGroup),
                        repository: repository,
                        resource_type: typeof (Ft.StatsEntry),
                        is_writable: true);

                foreach (var entry in existing) {
                    to_delete.append (entry);
                }

                yield to_delete.delete_async ();
            }

            Ft.StatsEntry[] saved = {};

            if (!snapshot.deleted && snapshot.entries.length > 0)
            {
                var to_save = (Gom.ResourceGroup) GLib.Object.@new (
                        typeof (Gom.ResourceGroup),
                        repository: repository,
                        resource_type: typeof (Ft.StatsEntry),
                        is_writable: true);

                foreach (var remote_entry in snapshot.entries)
                {
                    var entry = new Ft.StatsEntry ();
                    entry.repository = repository;
                    entry.time       = remote_entry.time;
                    entry.date       = remote_entry.date;
                    entry.offset     = remote_entry.offset;
                    entry.duration   = remote_entry.duration;
                    entry.category   = snapshot.category;
                    entry.source_id  = source_id;

                    to_save.append (entry);
                    saved += entry;
                }

                // Same as `StatsManager.process_item()`
                to_save.write_sync ();
            }

            // Let the stats views update. Imported entries have negative `source-id`,
            // so `on_entry_changed()` ignores them and they're not exported again.
            foreach (var entry in existing) {
                this.stats_manager.entry_deleted (entry);
            }

            foreach (var entry in saved) {
                this.stats_manager.entry_saved (entry);
            }
        }

        /*
         * Export
         */

        /**
         * Rebuild the set of exported snapshots by reading the device's own file.
         */
        private async void load_exported (GLib.File folder,
                                          string    device_id) throws GLib.Error
        {
            this.exported.remove_all ();

            var file = get_own_file (folder, device_id);

            if (!file.query_exists ()) {
                return;
            }

            uint8[] contents;
            yield file.load_contents_async (null, out contents, null);

            foreach (var line in ((string) contents).split ("\n"))
            {
                if (line.strip () == "") {
                    continue;
                }

                var snapshot = parse_snapshot (line);

                if (snapshot == null || snapshot.device != device_id) {
                    continue;
                }

                if (snapshot.deleted) {
                    this.exported.remove (snapshot.source);
                }
                else {
                    this.exported.insert (snapshot.source, compute_digest (snapshot.entries));
                }
            }
        }

        private static async void append_lines (GLib.File folder,
                                                string    device_id,
                                                owned string data) throws GLib.Error
        {
            var file   = get_own_file (folder, device_id);
            var prefix = "";

            // If a previous write was cut short (e.g. a crash), start on a fresh line
            // so the next record isn't glued to the incomplete one.
            if (file.query_exists ())
            {
                var info = yield file.query_info_async (GLib.FileAttribute.STANDARD_SIZE,
                                                        GLib.FileQueryInfoFlags.NONE,
                                                        GLib.Priority.DEFAULT,
                                                        null);

                if (info.get_size () > 0)
                {
                    var input = yield file.read_async (GLib.Priority.DEFAULT, null);
                    var last  = new uint8[1];

                    input.seek (-1, GLib.SeekType.END, null);
                    yield input.read_async (last, GLib.Priority.DEFAULT, null);
                    yield input.close_async (GLib.Priority.DEFAULT, null);

                    if (last[0] != '\n') {
                        prefix = "\n";
                    }
                }
            }

            var stream = yield file.append_to_async (GLib.FileCreateFlags.NONE,
                                                     GLib.Priority.DEFAULT,
                                                     null);
            size_t bytes_written;
            data = prefix + data;

            // Write all lines in one call to minimize the chance of the sync tool
            // picking up a partially written line. Readers ignore incomplete lines anyway.
            yield stream.write_all_async (data.data, GLib.Priority.DEFAULT, null, out bytes_written);
            yield stream.close_async (GLib.Priority.DEFAULT, null);
        }

        private async void export_changes (GLib.File folder,
                                           string    folder_device_id) throws GLib.Error
        {
            var groups     = new GLib.HashTable<string, GLib.GenericArray<Ft.StatsEntry>> (
                                    GLib.str_hash, GLib.str_equal);
            var categories = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
            var checked    = new GLib.GenericSet<string> (GLib.str_hash, GLib.str_equal);

            if (this.export_all)
            {
                this.export_all = false;
                this.pending.remove_all ();

                var entries = yield this.fetch_entries (
                        create_int64_filter ("source-id", 0, Comparison.GREATER_OR_EQUAL));

                foreach (var entry in entries)
                {
                    var key   = get_local_source_key (entry);
                    var group = groups.lookup (key);

                    if (group == null) {
                        group = new GLib.GenericArray<Ft.StatsEntry> ();
                        groups.insert (key, group);
                        categories.insert (key, entry.category);
                    }

                    group.add (entry);
                }

                // Every previously exported source is checked, so deletions are detected
                this.exported.foreach ((key, digest) => checked.add (key));
                groups.foreach ((key, group) => checked.add (key));
            }
            else
            {
                var pending = this.pending;
                this.pending = new GLib.HashTable<string, Ft.StatsEntry> (GLib.str_hash, GLib.str_equal);

                var keys = pending.get_keys ();

                foreach (var key in keys)
                {
                    var sample = pending.lookup (key);
                    var group  = new GLib.GenericArray<Ft.StatsEntry> ();

                    foreach (var entry in yield this.fetch_local_source (sample)) {
                        group.add (entry);
                    }

                    groups.insert (key, group);
                    categories.insert (key, sample.category);
                    checked.add (key);
                }
            }

            var data  = new GLib.StringBuilder ();
            var count = 0;
            var new_digests = new GLib.HashTable<string, string?> (GLib.str_hash, GLib.str_equal);

            checked.foreach (
                (key) => {
                    var group  = groups.lookup (key);
                    var digest = group != null && group.length > 0
                            ? compute_digest (group.data)
                            : null;

                    if (digest == this.exported.lookup (key)) {
                        return;
                    }

                    var category = categories.lookup (key);

                    if (category == null) {
                        // Deleted source not seen in this pass; category is the key prefix
                        category = key.substring (0, key.index_of_char (':'));
                    }

                    Ft.StatsEntry[] entries = {};

                    if (digest != null) {
                        foreach (var entry in group.data) {
                            entries += entry;
                        }
                    }

                    data.append (serialize_snapshot (folder_device_id,
                                                     key,
                                                     category,
                                                     entries,
                                                     digest == null));
                    data.append_c ('\n');
                    new_digests.insert (key, digest);
                    count++;
                });

            if (count == 0) {
                return;
            }

            yield append_lines (folder, folder_device_id, data.str);

            // Sync may have been reconfigured meanwhile
            if (folder != this.folder) {
                return;
            }

            // Only record exports after a successful write
            new_digests.foreach (
                (key, digest) => {
                    if (digest != null) {
                        this.exported.insert (key, digest);
                    }
                    else {
                        this.exported.remove (key);
                    }
                });

            GLib.debug ("Sync: exported %d record(s)", count);
        }

        /*
         * Import
         */

        private async void load_imported () throws GLib.Error
        {
            var imported = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
            var groups   = new GLib.HashTable<string, GLib.GenericArray<Ft.StatsEntry>> (
                                  GLib.str_hash, GLib.str_equal);

            var entries = yield this.fetch_entries (
                    create_int64_filter ("source-id", 0, Comparison.LESS_THAN));

            foreach (var entry in entries)
            {
                var key   = entry.source_id.to_string ();
                var group = groups.lookup (key);

                if (group == null) {
                    group = new GLib.GenericArray<Ft.StatsEntry> ();
                    groups.insert (key, group);
                }

                group.add (entry);
            }

            groups.foreach ((key, group) => imported.insert (key, compute_digest (group.data)));

            this.imported = imported;
        }

        /**
         * Read new complete lines from a remote file. Returns latest snapshot per source.
         */
        private async void read_remote_file (GLib.File                        file,
                                             int64                            size,
                                             string                           device_id,
                                             GLib.HashTable<string, Snapshot> snapshots)
                                             throws GLib.Error
        {
            var name   = file.get_basename ();
            var offset = this.offsets.lookup (name);
            int64 start = offset != null ? offset : 0;

            // Nothing new since last read
            if (size == start) {
                return;
            }

            uint8[] contents;
            yield file.load_contents_async (null, out contents, null);

            // File was replaced or truncated, read it again from the start
            if (start > contents.length) {
                start = 0;
            }

            // Only consume complete lines; a partially synced line will be read later
            var end = (int64) contents.length;

            while (end > start && contents[end - 1] != '\n') {
                end--;
            }

            if (end <= start) {
                return;
            }

            // `load_contents()` always NUL-terminates, so the buffer is a valid C string
            var chunk = ((string) contents).substring ((long) start, (long) (end - start));

            foreach (var line in chunk.split ("\n"))
            {
                if (line.strip () == "") {
                    continue;
                }

                var snapshot = parse_snapshot (line);

                // Ignore records that claim to come from this device
                if (snapshot == null || snapshot.device == device_id) {
                    continue;
                }

                this.remote_devices.add (snapshot.device);
                snapshots.insert (@"$(snapshot.device)/$(snapshot.source)", snapshot);
            }

            this.offsets.insert (name, end);
        }

        private async void import_changes (GLib.File folder,
                                           string    device_id) throws GLib.Error
        {
            if (this.import_all) {
                this.import_all = false;
                this.offsets.remove_all ();
                this.remote_devices.remove_all ();
                this.imported = null;
            }

            if (this.imported == null) {
                yield this.load_imported ();
            }

            var snapshots  = new GLib.HashTable<string, Snapshot> (GLib.str_hash, GLib.str_equal);
            var enumerator = yield folder.enumerate_children_async (
                    GLib.FileAttribute.STANDARD_NAME + "," +
                    GLib.FileAttribute.STANDARD_TYPE + "," +
                    GLib.FileAttribute.STANDARD_SIZE,
                    GLib.FileQueryInfoFlags.NONE,
                    GLib.Priority.DEFAULT,
                    null);
            var own_name = device_id + FILE_EXTENSION;

            while (true)
            {
                var infos = yield enumerator.next_files_async (50, GLib.Priority.DEFAULT, null);

                if (infos == null) {
                    break;
                }

                foreach (var info in infos)
                {
                    var name = info.get_name ();

                    if (info.get_file_type () != GLib.FileType.REGULAR ||
                        name == own_name ||
                        !is_device_file (name))
                    {
                        continue;
                    }

                    try {
                        yield this.read_remote_file (folder.get_child (name),
                                                     info.get_size (),
                                                     device_id,
                                                     snapshots);
                    }
                    catch (GLib.Error error) {
                        GLib.warning ("Sync: failed to read %s: %s", name, error.message);
                    }
                }
            }

            var applied = 0;

            foreach (var snapshot in snapshots.get_values ())
            {
                // Sync may have been reconfigured meanwhile
                if (folder != this.folder || this.imported == null) {
                    return;
                }

                var source_id = get_imported_source_id (snapshot.device, snapshot.source);
                var key       = source_id.to_string ();
                var digest    = snapshot.deleted ? null : compute_digest (snapshot.entries);

                if (digest == "") {
                    digest = null;
                }

                if (digest == this.imported.lookup (key)) {
                    continue;
                }

                yield this.apply_snapshot (snapshot, source_id);

                if (digest != null) {
                    this.imported.insert (key, digest);
                }
                else {
                    this.imported.remove (key);
                }

                applied++;
            }

            if (applied > 0) {
                GLib.debug ("Sync: imported %d record(s)", applied);
            }
        }

        /*
         * Scheduling
         */

        private async void run ()
        {
            if (this.is_running) {
                this.run_again = true;
                return;
            }

            this.is_running = true;

            do {
                this.run_again = false;

                var folder    = this.folder;
                var device_id = this.device_id;

                if (!this.active || folder == null) {
                    break;
                }

                try {
                    yield this.export_changes (folder, device_id);
                    yield this.import_changes (folder, device_id);

                    this.last_error = null;
                    this.last_sync_time = new GLib.DateTime.now_local ();
                }
                catch (GLib.Error error) {
                    GLib.warning ("Sync failed: %s", error.message);
                    this.last_error = error.message;
                }
            }
            while (this.run_again);

            this.is_running = false;
            this.update_status ();

            foreach (unowned var callback in this.idle_callbacks) {
                callback.func ();
            }

            this.idle_callbacks = {};
        }

        private void schedule_export ()
        {
            if (!this.active || this.export_timeout_id != 0) {
                return;
            }

            this.export_timeout_id = GLib.Timeout.add_seconds (EXPORT_DELAY, () => {
                this.export_timeout_id = 0;
                this.run.begin ();

                return GLib.Source.REMOVE;
            });
        }

        private void schedule_import ()
        {
            if (!this.active) {
                return;
            }

            if (this.import_timeout_id != 0) {
                GLib.Source.remove (this.import_timeout_id);
            }

            this.import_timeout_id = GLib.Timeout.add_seconds (IMPORT_DELAY, () => {
                this.import_timeout_id = 0;
                this.run.begin ();

                return GLib.Source.REMOVE;
            });
        }

        /**
         * Export everything that changed and re-read all remote files.
         */
        public void sync_now ()
        {
            if (!this.active) {
                return;
            }

            this.export_all = true;
            this.import_all = true;
            this.run.begin ();
        }

        /**
         * Export pending changes. Called before quitting the app.
         */
        public async void flush ()
        {
            yield this.stats_manager.flush ();

            if (!this.active) {
                return;
            }

            if (this.export_timeout_id != 0) {
                GLib.Source.remove (this.export_timeout_id);
                this.export_timeout_id = 0;
            }

            if (this.is_running) {
                this.idle_callbacks += new Ft.AsyncCallback (this.flush.callback);
                yield;
            }

            if (this.pending.size () == 0 && !this.export_all) {
                return;
            }

            this.is_running = true;

            try {
                yield this.export_changes (this.folder, this.device_id);
            }
            catch (GLib.Error error) {
                GLib.warning ("Sync: failed to export changes: %s", error.message);
            }

            this.is_running = false;
        }

        /*
         * Lifecycle
         */

        private void start (GLib.File folder)
        {
            try {
                this.device_id = load_or_create_device_id ();

                if (!folder.query_exists ()) {
                    folder.make_directory_with_parents ();
                }
            }
            catch (GLib.Error error) {
                GLib.warning ("Sync: failed to start: %s", error.message);
                this.last_error = error.message;
                this.update_status ();
                return;
            }

            this.folder = folder;
            this.active = true;
            this.last_error = null;
            this.last_sync_time = null;

            try {
                this.monitor = folder.monitor_directory (GLib.FileMonitorFlags.WATCH_MOVES, null);
                this.monitor.changed.connect (this.on_folder_changed);
            }
            catch (GLib.Error error) {
                GLib.info ("Sync: folder monitoring unavailable, polling instead: %s", error.message);
            }

            this.poll_timeout_id = GLib.Timeout.add_seconds (POLL_INTERVAL, () => {
                this.run.begin ();

                return GLib.Source.CONTINUE;
            });

            this.load_exported.begin (
                folder,
                this.device_id,
                (obj, res) => {
                    try {
                        this.load_exported.end (res);
                    }
                    catch (GLib.Error error) {
                        GLib.warning ("Sync: failed to read own sync file: %s",
                                      error.message);
                    }

                    // Reconcile: export anything changed while sync was off,
                    // and re-read every remote file.
                    this.sync_now ();
                });

            this.update_status ();
        }

        private void stop ()
        {
            if (this.export_timeout_id != 0) {
                GLib.Source.remove (this.export_timeout_id);
                this.export_timeout_id = 0;
            }

            if (this.import_timeout_id != 0) {
                GLib.Source.remove (this.import_timeout_id);
                this.import_timeout_id = 0;
            }

            if (this.poll_timeout_id != 0) {
                GLib.Source.remove (this.poll_timeout_id);
                this.poll_timeout_id = 0;
            }

            if (this.monitor != null) {
                this.monitor.changed.disconnect (this.on_folder_changed);
                this.monitor.cancel ();
                this.monitor = null;
            }

            this.active = false;
            this.folder = null;
            this.imported = null;
            this.exported.remove_all ();
            this.pending.remove_all ();
            this.offsets.remove_all ();
            this.remote_devices.remove_all ();
        }

        private void reconfigure ()
        {
            this.stop ();

            var enabled     = this.settings.get_boolean ("sync-enabled");
            var folder_path = this.settings.get_string ("sync-folder");

            if (enabled && folder_path != "" && !Ft.is_test ()) {
                this.start (GLib.File.new_for_path (folder_path));
            }
            else {
                this.update_status ();
            }
        }

        private void update_status ()
        {
            string status;

            if (!this.settings.get_boolean ("sync-enabled")) {
                status = _("Off");
            }
            else if (this.settings.get_string ("sync-folder") == "") {
                status = _("Choose a shared folder to start syncing");
            }
            else if (this.last_error != null) {
                status = _("Error: %s").printf (this.last_error);
            }
            else if (this.last_sync_time == null) {
                status = _("Syncing…");
            }
            else {
                var devices = this.remote_devices.length;
                var time    = this.last_sync_time.format ("%X");

                status = devices == 0
                        ? _("Up to date at %s · No other devices yet").printf (time)
                        : ngettext ("Up to date at %s · %u other device",
                                    "Up to date at %s · %u other devices",
                                    devices).printf (time, devices);
            }

            if (this.status != status) {
                this.status = status;
            }
        }

        /*
         * Signal handlers
         */

        private void on_settings_changed (GLib.Settings settings,
                                          string        key)
        {
            if (key == "sync-enabled" || key == "sync-folder") {
                this.reconfigure ();
            }
        }

        private void on_entry_changed (Ft.StatsEntry entry)
        {
            // Negative ids mark imported entries
            if (!this.active || entry.source_id < 0) {
                return;
            }

            this.pending.insert (get_local_source_key (entry), entry.copy ());
            this.schedule_export ();
        }

        private void on_folder_changed (GLib.File          file,
                                        GLib.File?         other_file,
                                        GLib.FileMonitorEvent event_type)
        {
            var name = (other_file ?? file).get_basename ();

            if (name == null || !is_device_file (name) || name == this.device_id + FILE_EXTENSION) {
                return;
            }

            switch (event_type)
            {
                case GLib.FileMonitorEvent.CHANGES_DONE_HINT:
                case GLib.FileMonitorEvent.CREATED:
                case GLib.FileMonitorEvent.MOVED_IN:
                case GLib.FileMonitorEvent.RENAMED:
                case GLib.FileMonitorEvent.DELETED:
                    this.schedule_import ();
                    break;

                default:
                    break;
            }
        }

        public override void dispose ()
        {
            this.stop ();

            if (this.settings != null) {
                this.settings.changed.disconnect (this.on_settings_changed);
                this.settings = null;
            }

            if (this.stats_manager != null) {
                this.stats_manager.entry_saved.disconnect (this.on_entry_changed);
                this.stats_manager.entry_deleted.disconnect (this.on_entry_changed);
                this.stats_manager = null;
            }

            base.dispose ();
        }
    }
}
