/*
 * Copyright (c) 2026 focus-timer contributors
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace Ft
{
    [GtkTemplate (ui = "/io/github/focustimerhq/FocusTimer/ui/preferences/integrations/preferences-panel-integrations.ui")]
    public class PreferencesPanelIntegrations : Ft.PreferencesPanel
    {
        private const string[] GROUP_ORDER = {
            "autostart",
            "desktop",
            "media-playback",
            "sync",
        };

        [GtkChild]
        private unowned Adw.PreferencesPage page;
        [GtkChild]
        private unowned Adw.SwitchRow autostart_switchrow;
        [GtkChild]
        private unowned Adw.PreferencesGroup autostart_group;
        [GtkChild]
        private unowned Gtk.Label autostart_label;
        [GtkChild]
        private unowned Adw.PreferencesGroup sync_group;
        [GtkChild]
        private unowned Adw.SwitchRow sync_switchrow;
        [GtkChild]
        private unowned Adw.ActionRow sync_folder_row;
        [GtkChild]
        private unowned Adw.ActionRow sync_status_row;
        [GtkChild]
        private unowned Gtk.Button sync_now_button;

        private GLib.Settings?   settings = null;
        private Ft.SyncManager?  sync_manager = null;

        construct
        {
            this.settings = Ft.get_settings ();
            this.settings.bind (
                    "autostart",
                    this.autostart_switchrow,
                    "active",
                    GLib.SettingsBindFlags.DEFAULT);

            var background_manager = new Ft.BackgroundManager ();
            background_manager.bind_property (
                    "autostart-allowed",
                    this.autostart_label,
                    "visible",
                    GLib.BindingFlags.SYNC_CREATE);

            this.autostart_group.set_data<string> ("name", "autostart");

            // Sync
            this.sync_manager = new Ft.SyncManager ();

            this.settings.bind (
                    "sync-enabled",
                    this.sync_switchrow,
                    "active",
                    GLib.SettingsBindFlags.DEFAULT);
            this.sync_manager.bind_property (
                    "status",
                    this.sync_status_row,
                    "subtitle",
                    GLib.BindingFlags.SYNC_CREATE);
            this.sync_manager.bind_property (
                    "active",
                    this.sync_now_button,
                    "sensitive",
                    GLib.BindingFlags.SYNC_CREATE);
            this.settings.changed.connect (this.on_settings_changed);

            this.update_sync_folder_row ();

            this.sync_group.set_data<string> ("name", "sync");
        }

        private void update_sync_folder_row ()
        {
            var path = this.settings.get_string ("sync-folder");

            this.sync_folder_row.subtitle = path != ""
                    ? GLib.Markup.escape_text (path)
                    : _("Not selected");
        }

        private void on_settings_changed (GLib.Settings settings,
                                          string        key)
        {
            if (key == "sync-folder") {
                this.update_sync_folder_row ();
            }
        }

        [GtkCallback]
        private void on_sync_folder_button_clicked (Gtk.Button button)
        {
            var dialog = new Gtk.FileDialog ();
            dialog.title = _("Choose Shared Folder");
            dialog.modal = true;

            var path = this.settings.get_string ("sync-folder");

            if (path != "") {
                dialog.initial_folder = GLib.File.new_for_path (path);
            }

            dialog.select_folder.begin (
                this.get_root () as Gtk.Window,
                null,
                (obj, res) => {
                    try {
                        var folder = dialog.select_folder.end (res);
                        var folder_path = folder?.get_path ();

                        if (folder_path != null) {
                            this.settings.set_string ("sync-folder", folder_path);
                        }
                    }
                    catch (GLib.Error error) {
                        // Dismissed by user
                    }
                });
        }

        [GtkCallback]
        private void on_sync_now_button_clicked (Gtk.Button button)
        {
            this.sync_manager.sync_now ();
        }

        public override unowned Adw.PreferencesPage get_preferences_page ()
        {
            return this.page;
        }

        protected override unowned string[]? get_group_order ()
        {
            return GROUP_ORDER;
        }

        public override void dispose ()
        {
            if (this.settings != null) {
                this.settings.changed.disconnect (this.on_settings_changed);
            }

            this.settings = null;
            this.sync_manager = null;

            base.dispose ();
        }
    }
}
