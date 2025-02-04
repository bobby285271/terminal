// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
/*
* Copyright (c) 2011-2017 elementary LLC. (https://elementary.io)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU Lesser General Public
* License version 3, as published by the Free Software Foundation.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU Lesser General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1301 USA
*/

namespace Terminal {
    public class TerminalWidget : Vte.Terminal {
        enum DropTargets {
            URILIST,
            STRING,
            TEXT
        }

        internal const string DEFAULT_LABEL = _("Terminal");
        public Terminal.Application app;
        public string terminal_id;
        public string current_working_directory { get; private set; default = "";}
        static int terminal_id_counter = 0;
        private bool init_complete;
        public bool resized {get; set;}

        GLib.Pid child_pid;
        private MainWindow _window;

        public MainWindow window {
            get {
                return _window;
            }

            set {
                this._window = value;
                this.app = value.app;
                this.menu = value.menu;
                this.menu.show_all ();
            }
        }

        private Gtk.Menu menu;
        public Granite.Widgets.Tab tab;
        public string? link_uri;

        private string _tab_label;
        public string tab_label {
            get {
                return _tab_label;
            }

            set {
                if (value != null) {
                    _tab_label = value;
                    tab.label = tab_label;
                }
            }
        }

        public int default_size;
        const string SEND_PROCESS_FINISHED_BASH = "dbus-send --type=method_call " +
                                                  "--session --dest=io.elementary.terminal " +
                                                  "/io/elementary/terminal " +
                                                  "io.elementary.terminal.ProcessFinished " +
                                                  "string:$PANTHEON_TERMINAL_ID " +
                                                  "string:\"$(history 1 | cut -c 8-)\" " +
                                                  "int32:\$__bp_last_ret_value >/dev/null 2>&1";

        /* Following strings are used to build RegEx for matching URIs */
        const string USERCHARS = "-[:alnum:]";
        const string USERCHARS_CLASS = "[" + USERCHARS + "]";
        const string PASSCHARS_CLASS = "[-[:alnum:]\\Q,?;.:/!%$^*&~\"#'\\E]";
        const string HOSTCHARS_CLASS = "[-[:alnum:]]";
        const string HOST = HOSTCHARS_CLASS + "+(\\." + HOSTCHARS_CLASS + "+)*";
        const string PORT = "(?:\\:[[:digit:]]{1,5})?";
        const string PATHCHARS_CLASS = "[-[:alnum:]\\Q_$.+!*,;:@&=?/~#%\\E]";
        const string PATHTERM_CLASS = "[^\\Q]'.}>) \t\r\n,\"\\E]";
        const string SCHEME = "(?:news:|telnet:|nntp:|file:\\/|https?:|ftps?:|sftp:|webcal:" +
                              "|irc:|sftp:|ldaps?:|nfs:|smb:|rsync:|ssh:|rlogin:|telnet:|git:" +
                              "|git\\+ssh:|bzr:|bzr\\+ssh:|svn:|svn\\+ssh:|hg:|mailto:|magnet:)";

        const string USERPASS = USERCHARS_CLASS + "+(?:" + PASSCHARS_CLASS + "+)?";
        const string URLPATH = "(?:(/" + PATHCHARS_CLASS +
                               "+(?:[(]" + PATHCHARS_CLASS +
                               "*[)])*" + PATHCHARS_CLASS +
                               "*)*" + PATHTERM_CLASS +
                               ")?";

        const string[] REGEX_STRINGS = {
            SCHEME + "//(?:" + USERPASS + "\\@)?" + HOST + PORT + URLPATH,
            "(?:www|ftp)" + HOSTCHARS_CLASS + "*\\." + HOST + PORT + URLPATH,
            "(?:callto:|h323:|sip:)" + USERCHARS_CLASS + "[" + USERCHARS + ".]*(?:" + PORT + "/[a-z0-9]+)?\\@" + HOST,
            "(?:mailto:)?" + USERCHARS_CLASS + "[" + USERCHARS + ".]*\\@" + HOSTCHARS_CLASS + "+\\." + HOST,
            "(?:news:|man:|info:)[[:alnum:]\\Q^_{|}~!\"#$%&'()*+,./;:=?`\\E]+"
        };

        public const double MIN_SCALE = 0.25;
        public const double MAX_SCALE = 4.0;

        public bool child_has_exited {
            get;
            private set;
        }

        public bool killed {
            get;
            private set;
        }

        private long remembered_position; /* Only need to remember row at the moment */
        private long remembered_command_start_row = 0; /* Only need to remember row at the moment */
        private long remembered_command_end_row = 0; /* Only need to remember row at the moment */
        public bool last_key_was_return = true;

        private double total_delta_y = 0.0;

        public signal void cwd_changed ();

        public TerminalWidget (MainWindow parent_window) {
            pointer_autohide = true;

            terminal_id = "%i".printf (terminal_id_counter++);

            init_complete = false;

            window = parent_window;
            child_has_exited = false;
            killed = false;

            update_audible_bell ();
            update_cursor_shape ();
            update_theme ();

            var granite_settings = Granite.Settings.get_default ();
            granite_settings.notify["prefers-color-scheme"].connect (update_theme);
            Application.settings.changed["audible-bell"].connect (update_audible_bell);
            Application.settings.changed["background"].connect (update_theme);
            Application.settings.changed["cursor-color"].connect (update_theme);
            Application.settings.changed["cursor-shape"].connect (update_cursor_shape);
            Application.settings.changed["follow-system-style"].connect (update_theme);
            Application.settings.changed["foreground"].connect (update_theme);
            Application.settings.changed["palette"].connect (update_theme);
            Application.settings.changed["prefer-dark-style"].connect (update_theme);
            Application.settings.changed["theme"].connect (update_theme);

            button_press_event.connect ((event) => {
                link_uri = null;
                /* If this event caused focus-in then window.focus_timeout is > 0
                 * and we need to suppress following hyperlinks on button release.
                 * If focus-in was caused by keyboard then the focus_timeout will have
                 * expired and we can follow hyperlinks */
                allow_hyperlink = window.focus_timeout == 0;

                if (event.button == Gdk.BUTTON_SECONDARY) {
                    link_uri = get_link (event);
                    if (link_uri != null) {
                        window.get_simple_action (MainWindow.ACTION_COPY).set_enabled (true);
                    }

                    window.update_context_menu ();

                    menu.popup_at_pointer (event);
                    menu.select_first (false);

                    return true;
                }

                return false;
            });

            button_release_event.connect ((event) => {

                if (event.button == Gdk.BUTTON_PRIMARY) {
                    if (allow_hyperlink) {
                        link_uri = get_link (event);

                        if (link_uri != null && !get_has_selection ()) {
                           window.get_simple_action (MainWindow.ACTION_OPEN_IN_BROWSER).activate (null);
                        }
                    } else {
                        allow_hyperlink = true;
                    }
                }

                return false;
            });

            scroll_event.connect ((event) => {
                if ((event.state & Gdk.ModifierType.CONTROL_MASK) > 0) {
                    switch (event.direction) {
                        case Gdk.ScrollDirection.UP:
                            increment_size ();
                            return Gdk.EVENT_STOP;

                        case Gdk.ScrollDirection.DOWN:
                            decrement_size ();
                            return Gdk.EVENT_STOP;

                        case Gdk.ScrollDirection.SMOOTH:
                            /* try to emulate a normal scrolling event by summing deltas.
                             * step size of 0.5 chosen to match sensitivity */
                            total_delta_y += event.delta_y;

                            if (total_delta_y >= 0.5) {
                                total_delta_y = 0;
                                decrement_size ();
                            } else if (total_delta_y <= -0.5) {
                                total_delta_y = 0;
                                increment_size ();
                            }

                            return Gdk.EVENT_STOP;

                        default:
                            break;
                    }
                }

                return Gdk.EVENT_PROPAGATE;
            });

            selection_changed.connect (() => {
                window.get_simple_action (MainWindow.ACTION_COPY).set_enabled (get_has_selection ());
                window.update_context_menu ();
            });

            size_allocate.connect (() => {
                resized = true;
            });

            contents_changed.connect (check_cwd_changed);

            child_exited.connect (on_child_exited);

            /* target entries specify what kind of data the terminal widget accepts */
            Gtk.TargetEntry uri_entry = { "text/uri-list", Gtk.TargetFlags.OTHER_APP, DropTargets.URILIST };
            Gtk.TargetEntry string_entry = { "STRING", Gtk.TargetFlags.OTHER_APP, DropTargets.STRING };
            Gtk.TargetEntry text_entry = { "text/plain", Gtk.TargetFlags.OTHER_APP, DropTargets.TEXT };

            Gtk.TargetEntry[] targets = { };
            targets += uri_entry;
            targets += string_entry;
            targets += text_entry;

            Gtk.drag_dest_set (this, Gtk.DestDefaults.ALL, targets, Gdk.DragAction.COPY);

            /* Make Links Clickable */
            this.drag_data_received.connect (drag_received);
            this.clickable (REGEX_STRINGS);
        }

        private void update_theme () {
            var gtk_settings = Gtk.Settings.get_default ();
            var theme_palette = new Gdk.RGBA[Themes.PALETTE_SIZE];
            if (Application.settings.get_boolean ("follow-system-style")) {
                var system_prefers_dark = Granite.Settings.get_default ().prefers_color_scheme == Granite.Settings.ColorScheme.DARK;
                gtk_settings.gtk_application_prefer_dark_theme = system_prefers_dark;

                if (system_prefers_dark) {
                    theme_palette = Themes.get_rgba_palette (Themes.DARK);
                } else {
                    theme_palette = Themes.get_rgba_palette (Themes.LIGHT);
                }
            } else {
                gtk_settings.gtk_application_prefer_dark_theme = Application.settings.get_boolean ("prefer-dark-style");
                theme_palette = Themes.get_rgba_palette (Application.settings.get_string ("theme"));
            }

            var background = theme_palette[Themes.PALETTE_SIZE - 3];
            var foreground = theme_palette[Themes.PALETTE_SIZE - 2];
            var cursor = theme_palette[Themes.PALETTE_SIZE - 1];
            var palette = theme_palette[0:16];

            set_colors (foreground, background, palette);
            set_color_cursor (cursor);
        }

        private void update_audible_bell () {
            audible_bell = Application.settings.get_boolean ("audible-bell");
        }

        private void update_cursor_shape () {
            set_cursor_shape ((Vte.CursorShape) Application.settings.get_enum ("cursor-shape"));
        }

        void on_child_exited () {
            child_has_exited = true;
            last_key_was_return = true;
        }

        public void kill_fg () {
            int fg_pid;
            if (this.try_get_foreground_pid (out fg_pid))
                Posix.kill (fg_pid, Posix.Signal.KILL);
        }

        public void term_ps () {
            killed = true;

            /* Check if the shell process is still alive by sending 0 signals */
            while (Posix.kill (this.child_pid, 0) == 0) {
                Posix.kill (this.child_pid, Posix.Signal.HUP);
                Posix.kill (this.child_pid, Posix.Signal.TERM);
                Thread.usleep (100);
            }
        }

        public void active_shell (string dir = GLib.Environment.get_current_dir ()) {
            string shell = Application.settings.get_string ("shell");
            string?[] envv = null;

            if (shell == "")
                shell = Vte.get_user_shell ();

            envv = {
                // Export ID so we can identify the terminal for which the process completion is reported
                "PANTHEON_TERMINAL_ID=" + terminal_id,

                // Export callback command a BASH-specific variable, see "man bash" for details
                "PROMPT_COMMAND=" + SEND_PROCESS_FINISHED_BASH + Environment.get_variable ("PROMPT_COMMAND"),

                // ZSH callback command will be read from ZSH config file supplied by us, see data/

                // TODO: support FISH, see https://github.com/fish-shell/fish-shell/issues/1382
            };

            /* We need opening uri to be available asap when constructing window with working directory
             * so remove idle loop, which appears not to be necessary any longer */
            try {
                this.spawn_sync (Vte.PtyFlags.DEFAULT, dir, { shell },
                                        envv, SpawnFlags.SEARCH_PATH, null, out this.child_pid, null);
            } catch (Error e) {
                warning (e.message);
            }

            check_cwd_changed ();
        }

        public void run_program (string program_string, string? working_directory) {
            try {
                string[]? program_with_args = null;
                Shell.parse_argv (program_string, out program_with_args);

                this.spawn_sync (Vte.PtyFlags.DEFAULT, working_directory, program_with_args,
                                        null, SpawnFlags.SEARCH_PATH, null, out this.child_pid, null);
            } catch (Error e) {
                warning (e.message);
                feed ((e.message + "\r\n\r\n").data);
                active_shell (working_directory);
            }
        }

        public bool try_get_foreground_pid (out int pid) {
            if (child_has_exited) {
                pid = -1;
                return false;
            }

            int pty = get_pty ().fd;
            int fgpid = Posix.tcgetpgrp (pty);

            if (fgpid != this.child_pid && fgpid != -1) {
                pid = (int) fgpid;
                return true;
            } else {
                pid = -1;
                return false;
            }
        }

        public bool has_foreground_process () {
            return try_get_foreground_pid (null);
        }

        public int calculate_width (int column_count) {
            int width = (int) (this.get_char_width ()) * column_count;
            return width;
        }

        public int calculate_height (int row_count) {
            int height = (int) (this.get_char_height ()) * row_count;
            return height;
        }

        private void clickable (string[] str) {
            foreach (unowned string exp in str) {
                try {
                    var regex = new Vte.Regex.for_match (exp, -1, PCRE2.Flags.MULTILINE);
                    int id = this.match_add_regex (regex, 0);
                    this.match_set_cursor_name (id, "pointer");
                } catch (GLib.Error error) {
                    warning (error.message);
                }
            }
        }

        private string? get_link (Gdk.Event event) {
            return this.match_check_event (event, null);
        }

        public string get_shell_location () {
            int pid = (!) (this.child_pid);

            try {
                return GLib.FileUtils.read_link ("/proc/%d/cwd".printf (pid));
            } catch (GLib.FileError error) {
                /* Tab name disambiguation may call this before shell location available. */
                /* No terminal warning needed */
                return "";
            }
        }

        public void increment_size () {
            font_scale = (font_scale + 0.1).clamp (MIN_SCALE, MAX_SCALE);
        }

        public void decrement_size () {
            font_scale = (font_scale - 0.1).clamp (MIN_SCALE, MAX_SCALE);
        }

        public void set_default_font_size () {
            font_scale = 1.0;
        }

        public bool is_init_complete () {
            return init_complete;
        }

        public void set_init_complete () {
            init_complete = true;
        }

        public void drag_received (Gdk.DragContext context, int x, int y,
                                   Gtk.SelectionData selection_data, uint target_type, uint time_) {
            switch (target_type) {
                case DropTargets.URILIST:
                    var uris = selection_data.get_uris ();
                    string path;
                    File file;

                    for (var i = 0; i < uris.length; i++) {
                         file = File.new_for_uri (uris[i]);
                         if ((path = file.get_path ()) != null) {
                             uris[i] = Shell.quote (path) + " ";
                        }
                    }

                    var uris_s = string.joinv ("", uris);
                    this.feed_child (uris_s.data);
                    break;
                case DropTargets.STRING:
                case DropTargets.TEXT:
                    var data = selection_data.get_text ();

                    if (data != null) {
                        this.feed_child (data.data);
                    }

                    break;
            }
        }

        public void remember_position () {
            long col, row;
            get_cursor_position (out col, out row);
            remembered_position = row;
        }

        public void remember_command_start_position () {
            if (!last_key_was_return || has_foreground_process ()) {
                return;
            }

            long col, row;
            get_cursor_position (out col, out row);
            remembered_command_start_row = row;
            last_key_was_return = false;
            resized = false;
        }

        public void remember_command_end_position () {
            if (last_key_was_return && !has_foreground_process ()) {
                return;
            }

            long col, row;
            get_cursor_position (out col, out row);
            /* Password entry will be on next line, or, if an incorrect password is given, two lines ahead */
            /* This restriction is required for `include_command = false to work` (although not currently used) */
            if (row - remembered_command_end_row <= 2) {
                remembered_command_end_row = row;
            }

            last_key_was_return = true;
        }

        public string get_last_output (bool include_command = true) {
            long output_end_col, output_end_row, start_row;
            get_cursor_position (out output_end_col, out output_end_row);

            var command_lines = remembered_command_end_row - remembered_command_start_row;

            if (!include_command) {
                start_row = remembered_command_end_row + 1;
            } else {
                start_row = remembered_command_start_row;
            }

            if (output_end_row - start_row < (include_command ? command_lines + 1 : 1)) {
                return "";
            }

            last_key_was_return = true;

            /* get text to the beginning of current line (to omit last prompt)
             * Note that using end_row, 0 for the end parameters results in the first
             * character of the prompt being selected for some reason. We assume a nominal
             * maximum line length rather than determine the actual length.  */
            return get_text_range (start_row, 0, output_end_row - 1, 1000, null, null) + "\n";
        }

        public void scroll_to_last_command () {
            long col, row;
            get_cursor_position (out col, out row);
            int delta = (int)(remembered_position - row);
            vadjustment.set_value (
                vadjustment.get_value () + delta + get_window ().get_height () / get_char_height () - 1
            );
        }

        public bool has_output () {
            return !resized && get_last_output ().length > 0;
        }

        public void reload () {
            if (has_foreground_process ()) {
                var dialog = new ForegroundProcessDialog.before_tab_reload (window);
                var response_type = dialog.run ();
                dialog.destroy ();

                if (response_type != Gtk.ResponseType.ACCEPT) {
                    return;
                }
            }

            var old_loc = get_shell_location ();
            Posix.kill (child_pid, Posix.Signal.TERM);
            reset (true, true);
            active_shell (old_loc);
        }

        private void check_cwd_changed () {
            var cwd = get_shell_location ();
            if (cwd != current_working_directory) {
                current_working_directory = cwd;
                cwd_changed ();
            }
        }
    }
}
