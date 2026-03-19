
/*
 * TeeJee.System.vala
 *
 * Copyright 2012-2018 Tony George <teejeetech@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301, USA.
 *
 *
 */
 
namespace TeeJee.System{

	using TeeJee.ProcessHelper;
	using TeeJee.Logging;
	using TeeJee.Misc;
	using TeeJee.FileSystem;
	
	// user ---------------------------------------------------

	public bool user_is_admin(){
		
		return (get_user_id_effective() == 0);
	}
	
	public int get_user_id(){

		// returns actual user id of current user (even for applications executed with sudo, pkexec, or doas)
		
		string pkexec_uid = GLib.Environment.get_variable("PKEXEC_UID");

		if (pkexec_uid != null){
			return int.parse(pkexec_uid);
		}

		string sudo_user = GLib.Environment.get_variable("SUDO_UID");

		if (sudo_user != null){
			return int.parse(sudo_user);
		}

		// doas (used on Alpine Linux) sets DOAS_USER with the invoking username
		string doas_user = GLib.Environment.get_variable("DOAS_USER");

		if (doas_user != null){
			unowned Posix.Passwd? pw = Posix.getpwnam(doas_user);
			if (pw != null){
				return (int) pw.pw_uid;
			}
		}

		// Last-resort fallback for doas configurations that do not export DOAS_USER:
		// stat the XAUTHORITY file to find the display owner's UID.
		// setup_env() copies the user's XAUTHORITY path from their process environment,
		// so this file is always owned by the real (non-root) user.
		if (get_user_id_effective() == 0) {
			string? xauth = GLib.Environment.get_variable("XAUTHORITY");
			if (xauth != null && xauth.length > 0) {
				try {
					var xf = File.new_for_path(xauth);
					var xi = xf.query_info("unix::uid", FileQueryInfoFlags.NONE);
					int xuid = (int) xi.get_attribute_uint32("unix::uid");
					if (xuid > 0) {
						log_debug("get_user_id: detected uid %d from XAUTHORITY file owner".printf(xuid));
						return xuid;
					}
				} catch (Error e) {
					log_debug("get_user_id: failed to stat XAUTHORITY '%s': %s".printf(xauth, e.message));
				}
			}
		}

		return get_user_id_effective(); // normal user
	}

	private int euid = -1; // cache for get_user_id_effective (its never going to change)
	public int get_user_id_effective(){
		// returns effective user id (0 for applications executed with sudo and pkexec)
		if (euid < 0) {
			euid = (int) Posix.geteuid();
		}

		return euid;
	}
	
	public string? get_username_from_uid(int user_id){
		unowned Posix.Passwd? pw = Posix.getpwuid(user_id);
		string? outvalue = pw?.pw_name;
		if(null == outvalue) {
			log_error("Could not get username for uid %d".printf(user_id));
		}
		return outvalue;
	}

	// system ------------------------------------

	public double get_system_uptime_seconds(){

		/* Returns the system up-time in seconds */

		string uptime = file_read("/proc/uptime").split(" ")[0];
		double secs = double.parse(uptime);
		return secs;
	}

	// open -----------------------------

	public static bool xdg_open (string file){
		// When running as a GTK application, use GLib's AppInfo which leverages
		// the existing display/D-Bus session. Works on both X11 and Wayland.
		// NEVER use AppInfo when running as root: it would launch the target app
		// (browser, text editor) as root, which modern apps refuse or warn about.
		bool running_as_root = (TeeJee.System.get_user_id_effective() == 0);
		if (!running_as_root && GTK_INITIALIZED) {
			try {
				// Ensure we have a proper URI (URIs start with a scheme like "http://" or "file://")
				string uri = (file.index_of("://") >= 0) ? file : GLib.File.new_for_path(file).get_uri();
				Gdk.AppLaunchContext? ctx = null;
				var display = Gdk.Display.get_default();
				if (display != null) {
					ctx = display.get_app_launch_context();
				}
				GLib.AppInfo.launch_default_for_uri(uri, ctx);
				return true;
			} catch (Error e) {
				log_debug("xdg_open AppInfo: %s".printf(e.message));
			}
		}

		if (!TeeJee.ProcessHelper.cmd_exists("xdg-open")) {
			return false;
		}

		string cmd = "xdg-open '%s'".printf(escape_single_quote(file));

		return exec_user_async(cmd) == 0;
	}

	public bool exo_open_folder (string dir_path, bool xdg_open_try_first = true){

		/* Tries to open the given directory in a file manager */

		if (dir_path.length == 0) {
			log_debug("exo_open_folder: path is empty");
			return false;
		}

		string uri = GLib.File.new_for_path(dir_path).get_uri();
		string escaped = escape_single_quote(dir_path);

		// When running as root on behalf of a real user (sudo/pkexec/doas), or any
		// time we are root, skip GLib AppInfo.  AppInfo inherits the current euid,
		// so it would launch the file manager as root.  Modern file managers
		// (Nautilus 42+, Thunar 4.x, etc.) refuse to run as root and print warnings.
		// Run the file manager as the actual user via exec_user_async instead.
		bool running_as_root = (TeeJee.System.get_user_id_effective() == 0);

		if (!running_as_root && GTK_INITIALIZED) {
			try {
				Gdk.AppLaunchContext? ctx = null;
				var display = Gdk.Display.get_default();
				if (display != null) {
					ctx = display.get_app_launch_context();
				}
				GLib.AppInfo.launch_default_for_uri(uri, ctx);
				return true;
			} catch (Error e) {
				log_debug("exo_open_folder AppInfo: %s".printf(e.message));
				// fall through to subprocess path
			}
		}

		// Subprocess path — exec_user_async runs the command as the real user
		// (not root) so it sees the correct MIME handlers and D-Bus session.
		//
		// 'gio open' is always available (part of glib) and works without a
		// desktop-specific helper, making it the best choice on Alpine Linux.
		if (cmd_exists("gio")) {
			exec_user_async("gio open '%s'".printf(escape_single_quote(uri)));
			return true;
		}

		if (xdg_open_try_first && cmd_exists("xdg-open")) {
			exec_user_async("xdg-open '%s'".printf(escaped));
			return true;
		}

		foreach (string app in new string[]{
				"thunar", "nemo", "nautilus", "pcmanfm", "dolphin",
				"io.elementary.files", "pantheon-files", "caja", "marlin"}) {
			if (!cmd_exists(app)) { continue; }
			exec_user_async("%s '%s'".printf(app, escaped));
			return true;
		}

		if (!xdg_open_try_first && cmd_exists("xdg-open")) {
			exec_user_async("xdg-open '%s'".printf(escaped));
			return true;
		}

		return false;
	}

	public bool using_efi_boot(){
		
		/* Returns true if the system was booted in EFI mode
		 * and false for BIOS mode */
		 
		return dir_exists("/sys/firmware/efi");
	}

	// timers --------------------------------------------------
	
	public GLib.Timer timer_start(){
		var timer = new GLib.Timer();
		timer.start();
		return timer;
	}

	public ulong timer_elapsed(GLib.Timer timer, bool stop = true){
		ulong microseconds;
		double seconds;
		seconds = timer.elapsed (out microseconds);
		if (stop){
			timer.stop();
		}
		return (ulong)((seconds * 1000 ) + (microseconds / 1000));
	}

	public void sleep(int milliseconds){
		Thread.usleep ((ulong) milliseconds * 1000);
	}

	public string timer_elapsed_string(GLib.Timer timer, bool stop = true){
		ulong microseconds;
		double seconds;
		seconds = timer.elapsed (out microseconds);
		if (stop){
			timer.stop();
		}
		return "%.0f ms".printf((seconds * 1000 ) + microseconds/1000);
	}

	public void set_numeric_locale(string type){
		Intl.setlocale(GLib.LocaleCategory.NUMERIC, type);
	    Intl.setlocale(GLib.LocaleCategory.COLLATE, type);
	    Intl.setlocale(GLib.LocaleCategory.TIME, type);
	}
}
