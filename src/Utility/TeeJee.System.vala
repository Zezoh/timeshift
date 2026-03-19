
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
		if (GTK_INITIALIZED) {
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

		// When running as a GTK application, use GLib's AppInfo which leverages
		// the existing display/D-Bus session. This is the most reliable approach
		// and works on both X11 and Wayland without requiring a subprocess.
		if (GTK_INITIALIZED) {
			try {
				string uri = GLib.File.new_for_path(dir_path).get_uri();
				Gdk.AppLaunchContext? ctx = null;
				var display = Gdk.Display.get_default();
				if (display != null) {
					ctx = display.get_app_launch_context();
				}
				GLib.AppInfo.launch_default_for_uri(uri, ctx);
				return true;
			} catch (Error e) {
				log_debug("exo_open_folder AppInfo: %s".printf(e.message));
			}
		}

		// Subprocess fallback: used in CLI mode (GTK_INITIALIZED == false) or if AppInfo failed.
		// exec_user_async handles user-switching when timeshift runs as root (via sudo/pkexec).
		/*
		xdg-open is a desktop-independent tool for configuring the default applications of a user.
		Inside a desktop environment (e.g. GNOME, KDE, Xfce), xdg-open simply passes the arguments
		to that desktop environment's file-opener application (gvfs-open, kde-open, exo-open, respectively).
		We will first try using xdg-open and then check for specific file managers if it fails.
		*/

		bool xdgAvailable = cmd_exists("xdg-open");
		string escaped_dir_path = escape_single_quote(dir_path);
		int status = -1;

		if (xdg_open_try_first && xdgAvailable){
			//try using xdg-open
			string cmd = "xdg-open '%s'".printf(escaped_dir_path);
			status = exec_user_async (cmd);
			return (status == 0);
		}

		foreach(string app_name in
			new string[]{ "nemo", "nautilus", "thunar", "io.elementary.files", "pantheon-files", "marlin", "dolphin" }){
			if(!cmd_exists(app_name)) {
				continue;
			}

			string cmd = "%s '%s'".printf(app_name, escaped_dir_path);
			status = exec_user_async (cmd);

			if(status == 0) {
				return true;
			}
		}

		if (!xdg_open_try_first && xdgAvailable){
			//try using xdg-open
			string cmd = "xdg-open '%s'".printf(escaped_dir_path);
			status = exec_user_async (cmd);
			return (status == 0);
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
