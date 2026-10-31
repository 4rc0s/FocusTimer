/*
 * This file is part of focus-timer
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace Tests
{
    public class SyncManagerTest : Tests.MainLoopTestSuite
    {
        private const string LOCAL_DEVICE = "00000000-0000-4000-8000-00000000000a";
        private const string REMOTE_DEVICE = "00000000-0000-4000-8000-00000000000b";

        private Ft.StatsManager?    stats_manager;
        private Ft.SyncManager?     sync_manager;
        private Ft.TimezoneHistory? timezone_history;
        private Gom.Repository?     repository;
        private GLib.File?          folder;
        private int64               now;

        public SyncManagerTest ()
        {
            this.add_test ("export", this.test_export);
            this.add_test ("export__idempotent", this.test_export__idempotent);
            this.add_test ("export__deletion", this.test_export__deletion);
            this.add_test ("import", this.test_import);
            this.add_test ("import__revision", this.test_import__revision);
            this.add_test ("import__deletion", this.test_import__deletion);
            this.add_test ("import__not_exported", this.test_import__not_exported);
            this.add_test ("import__invalid_lines", this.test_import__invalid_lines);
            this.add_test ("import__incomplete_line", this.test_import__incomplete_line);
            this.add_test ("import__ignore_own_device", this.test_import__ignore_own_device);
            this.add_test ("import__same_source_on_two_devices",
                           this.test_import__same_source_on_two_devices);
            this.add_test ("import__sourceless_local_entry",
                           this.test_import__sourceless_local_entry);
        }

        public override void setup ()
        {
            base.setup ();

            Ft.Database.open ();

            // Sat January 01 2000 08:00:00 UTC
            this.now = Ft.Timestamp.from_seconds_uint (946713600);
            Ft.Timestamp.freeze_to (this.now);

            this.repository = Ft.Database.get_repository ();
            this.timezone_history = new Ft.TimezoneHistory ();
            this.timezone_history.insert (this.now, new GLib.TimeZone.utc ());

            this.stats_manager = new Ft.StatsManager ();
            this.sync_manager = new Ft.SyncManager ();

            try {
                this.folder = GLib.File.new_for_path (
                        GLib.DirUtils.make_tmp ("focus-timer-sync-XXXXXX"));
            }
            catch (GLib.Error error) {
                assert_no_error (error);
            }
        }

        public override void teardown ()
        {
            this.sync_manager.stop ();

            try {
                var enumerator = this.folder.enumerate_children (
                        GLib.FileAttribute.STANDARD_NAME, GLib.FileQueryInfoFlags.NONE);
                GLib.FileInfo? info;

                while ((info = enumerator.next_file ()) != null) {
                    this.folder.get_child (info.get_name ()).@delete ();
                }

                this.folder.@delete ();
            }
            catch (GLib.Error error) {
                assert_no_error (error);
            }

            this.timezone_history.clear_cache ();
            this.timezone_history = null;
            this.sync_manager = null;
            this.stats_manager = null;
            this.repository = null;
            this.folder = null;

            Ft.Timestamp.thaw ();
            Ft.Database.close ();

            base.teardown ();
        }

        /*
         * Helpers
         */

        private void start ()
        {
            var handler_id = this.sync_manager.synced.connect (() => this.quit_main_loop ());

            this.sync_manager.start_with_folder (this.folder, LOCAL_DEVICE);
            assert_true (this.run_main_loop ());

            this.sync_manager.disconnect (handler_id);
        }

        private void sync ()
        {
            var handler_id = this.sync_manager.synced.connect (() => this.quit_main_loop ());

            this.sync_manager.sync_now ();
            assert_true (this.run_main_loop ());

            this.sync_manager.disconnect (handler_id);
        }

        private void flush ()
        {
            this.sync_manager.flush.begin (
                (obj, res) => {
                    this.sync_manager.flush.end (res);
                    this.quit_main_loop ();
                });

            assert_true (this.run_main_loop ());
        }

        private void track (int64 source_id,
                            int64 minutes)
        {
            this.stats_manager.track ("pomodoro",
                                      this.now,
                                      minutes * Ft.Interval.MINUTE,
                                      source_id);
        }

        private string[] read_lines (string device_id)
        {
            var file = this.folder.get_child (device_id + ".jsonl");
            string[] lines = {};

            if (!file.query_exists ()) {
                return lines;
            }

            try {
                uint8[] contents;
                file.load_contents (null, out contents, null);

                foreach (var line in ((string) contents).split ("\n"))
                {
                    if (line != "") {
                        lines += line;
                    }
                }
            }
            catch (GLib.Error error) {
                assert_no_error (error);
            }

            return lines;
        }

        private void append_remote (string data)
        {
            var file = this.folder.get_child (REMOTE_DEVICE + ".jsonl");

            try {
                var stream = file.append_to (GLib.FileCreateFlags.NONE);
                stream.write_all (data.data, null);
                stream.close ();
            }
            catch (GLib.Error error) {
                assert_no_error (error);
            }
        }

        private static string make_record (string device,
                                           string source,
                                           int64  minutes,
                                           bool   deleted = false)
        {
            var entries = deleted
                    ? ""
                    : "[946713600000000,\"2000-01-01\",28800000000,%s]".printf (
                            (minutes * Ft.Interval.MINUTE).to_string ());

            return "{\"v\":1,\"device\":\"%s\",\"source\":\"%s\",\"category\":\"pomodoro\",%s\"entries\":[%s]}\n".printf (
                    device,
                    source,
                    deleted ? "\"deleted\":true," : "",
                    entries);
        }

        private Ft.StatsEntry[] fetch_entries ()
        {
            Ft.StatsEntry[] entries = {};

            try {
                var results = this.repository.find_sync (typeof (Ft.StatsEntry), null);

                if (results.count > 0) {
                    results.fetch_sync (0U, results.count);
                }

                for (var index = 0U; index < results.count; index++) {
                    entries += (Ft.StatsEntry) results.get_index (index);
                }
            }
            catch (GLib.Error error) {
                assert_no_error (error);
            }

            return entries;
        }

        private Ft.StatsEntry[] fetch_imported ()
        {
            Ft.StatsEntry[] entries = {};

            foreach (var entry in this.fetch_entries ())
            {
                if (entry.source_id < 0) {
                    entries += entry;
                }
            }

            return entries;
        }

        private Ft.AggregatedStatsEntry? fetch_aggregated ()
        {
            try {
                var value = GLib.Value (typeof (string));
                value.set_string ("pomodoro");

                return (Ft.AggregatedStatsEntry?) this.repository.find_one_sync (
                        typeof (Ft.AggregatedStatsEntry),
                        new Gom.Filter.eq (typeof (Ft.AggregatedStatsEntry), "category", value));
            }
            catch (GLib.Error error) {
                return null;
            }
        }

        /*
         * Export
         */

        public void test_export ()
        {
            this.start ();

            this.track (5, 25);
            this.flush ();

            var lines = this.read_lines (LOCAL_DEVICE);
            assert_cmpuint (lines.length, GLib.CompareOperator.EQ, 1U);
            assert_true (lines[0].contains ("\"source\":\"pomodoro:5\""));
            assert_true (lines[0].contains ("\"device\":\"%s\"".printf (LOCAL_DEVICE)));
            assert_true (lines[0].contains ((25 * Ft.Interval.MINUTE).to_string ()));
        }

        /**
         * Restarting must not export the same snapshot again.
         */
        public void test_export__idempotent ()
        {
            this.start ();

            this.track (5, 25);
            this.flush ();

            this.start ();
            this.sync ();

            assert_cmpuint (this.read_lines (LOCAL_DEVICE).length, GLib.CompareOperator.EQ, 1U);
        }

        /**
         * Changes made while sync was stopped are exported on start, including deletions.
         */
        public void test_export__deletion ()
        {
            this.start ();

            this.track (5, 25);
            this.flush ();

            this.sync_manager.stop ();

            try {
                foreach (var entry in this.fetch_entries ()) {
                    entry.delete_sync ();
                }
            }
            catch (GLib.Error error) {
                assert_no_error (error);
            }

            this.start ();

            var lines = this.read_lines (LOCAL_DEVICE);
            assert_cmpuint (lines.length, GLib.CompareOperator.EQ, 2U);
            assert_true (lines[1].contains ("\"deleted\":true"));
        }

        /*
         * Import
         */

        public void test_import ()
        {
            this.append_remote (make_record (REMOTE_DEVICE, "pomodoro:5", 30));
            this.start ();

            var imported = this.fetch_imported ();
            assert_cmpuint (imported.length, GLib.CompareOperator.EQ, 1U);
            assert_cmpvariant (new GLib.Variant.int64 (imported[0].duration),
                               new GLib.Variant.int64 (30 * Ft.Interval.MINUTE));
            assert_cmpstr (imported[0].date, GLib.CompareOperator.EQ, "2000-01-01");

            var aggregated = this.fetch_aggregated ();
            assert_nonnull (aggregated);
            assert_cmpvariant (new GLib.Variant.int64 (aggregated.count),
                               new GLib.Variant.int64 (1));
        }

        /**
         * A newer record for the same source replaces the previous one.
         */
        public void test_import__revision ()
        {
            this.append_remote (make_record (REMOTE_DEVICE, "pomodoro:5", 30));
            this.start ();

            this.append_remote (make_record (REMOTE_DEVICE, "pomodoro:5", 45));
            this.sync ();

            var imported = this.fetch_imported ();
            assert_cmpuint (imported.length, GLib.CompareOperator.EQ, 1U);
            assert_cmpvariant (new GLib.Variant.int64 (imported[0].duration),
                               new GLib.Variant.int64 (45 * Ft.Interval.MINUTE));

            var aggregated = this.fetch_aggregated ();
            assert_cmpvariant (new GLib.Variant.int64 (aggregated.count),
                               new GLib.Variant.int64 (1));
            assert_cmpvariant (new GLib.Variant.int64 (aggregated.duration),
                               new GLib.Variant.int64 (45 * Ft.Interval.MINUTE));
        }

        public void test_import__deletion ()
        {
            this.append_remote (make_record (REMOTE_DEVICE, "pomodoro:5", 30));
            this.start ();

            this.append_remote (make_record (REMOTE_DEVICE, "pomodoro:5", 0, true));
            this.sync ();

            assert_cmpuint (this.fetch_imported ().length, GLib.CompareOperator.EQ, 0U);

            var aggregated = this.fetch_aggregated ();
            assert_cmpvariant (new GLib.Variant.int64 (aggregated.count),
                               new GLib.Variant.int64 (0));
            assert_cmpvariant (new GLib.Variant.int64 (aggregated.duration),
                               new GLib.Variant.int64 (0));
        }

        /**
         * Imported entries must never be written to the device's own file.
         */
        public void test_import__not_exported ()
        {
            this.append_remote (make_record (REMOTE_DEVICE, "pomodoro:5", 30));
            this.start ();
            this.flush ();

            this.start ();
            this.flush ();

            assert_cmpuint (this.read_lines (LOCAL_DEVICE).length, GLib.CompareOperator.EQ, 0U);
        }

        public void test_import__invalid_lines ()
        {
            this.append_remote ("not json\n");
            this.append_remote ("{\"v\":99,\"device\":\"x\",\"source\":\"pomodoro:1\",\"category\":\"pomodoro\",\"entries\":[]}\n");
            this.append_remote ("{\"v\":1,\"device\":\"x\",\"source\":\"pomodoro:2\",\"category\":\"pomodoro\",\"entries\":[[\"bad\"]]}\n");
            this.append_remote (make_record (REMOTE_DEVICE, "pomodoro:5", 30));
            this.start ();

            assert_cmpuint (this.fetch_imported ().length, GLib.CompareOperator.EQ, 1U);
        }

        /**
         * A line still being transferred is skipped until it's complete.
         */
        public void test_import__incomplete_line ()
        {
            var record = make_record (REMOTE_DEVICE, "pomodoro:5", 30);
            var split  = record.length / 2;

            this.append_remote (record.substring (0, split));
            this.start ();

            assert_cmpuint (this.fetch_imported ().length, GLib.CompareOperator.EQ, 0U);

            this.append_remote (record.substring (split));
            this.sync ();

            assert_cmpuint (this.fetch_imported ().length, GLib.CompareOperator.EQ, 1U);
        }

        /**
         * Records claiming to come from this device are ignored, even in another file.
         */
        public void test_import__ignore_own_device ()
        {
            this.append_remote (make_record (LOCAL_DEVICE, "pomodoro:5", 30));
            this.start ();

            assert_cmpuint (this.fetch_entries ().length, GLib.CompareOperator.EQ, 0U);
        }

        /**
         * Local and remote entries with the same local source id must not collide.
         */
        public void test_import__same_source_on_two_devices ()
        {
            this.start ();

            this.track (5, 25);
            this.flush ();

            this.append_remote (make_record (REMOTE_DEVICE, "pomodoro:5", 30));
            this.sync ();

            var entries = this.fetch_entries ();
            assert_cmpuint (entries.length, GLib.CompareOperator.EQ, 2U);

            var aggregated = this.fetch_aggregated ();
            assert_cmpvariant (new GLib.Variant.int64 (aggregated.count),
                               new GLib.Variant.int64 (2));
            assert_cmpvariant (new GLib.Variant.int64 (aggregated.duration),
                               new GLib.Variant.int64 (55 * Ft.Interval.MINUTE));
        }

        /**
         * Tracking a local entry without a source must not overwrite an imported entry
         * that starts at the same time.
         */
        public void test_import__sourceless_local_entry ()
        {
            this.append_remote (make_record (REMOTE_DEVICE, "pomodoro:5", 30));
            this.start ();

            this.track (0, 25);
            this.flush ();

            assert_cmpuint (this.fetch_imported ().length, GLib.CompareOperator.EQ, 1U);
            assert_cmpuint (this.fetch_entries ().length, GLib.CompareOperator.EQ, 2U);
        }
    }
}


public static int main (string[] args)
{
    Tests.init (args);

    return Tests.run (
        new Tests.SyncManagerTest ()
    );
}
