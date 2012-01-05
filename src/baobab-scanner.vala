/* Baobab - disk usage analyzer
 *
 * Copyright (C) 2012  Ryan Lortie <desrt@desrt.ca>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

namespace Baobab {
	class Scanner : Gtk.TreeStore {
		public enum Columns {
			DISPLAY_NAME,
			PARSE_NAME,
			PERCENT,
			SIZE,
			ALLOC_SIZE,
			ELEMENTS,
			STATE,
			COLUMNS
		}

		public enum State {
			SCANNING,
			CANCELLED,
			NEED_PERCENT,
			DONE
		}

		struct HardLink {
			uint64 inode;
			uint32 device;

			public HardLink (FileInfo info) {
				this.inode = info.get_attribute_uint64 (FILE_ATTRIBUTE_UNIX_INODE);
				this.device = info.get_attribute_uint32 (FILE_ATTRIBUTE_UNIX_DEVICE);
			}
		}

		struct Results {
			uint64 size;
			uint64 alloc_size;
			uint64 elements;
			int max_depth;
		}

		Cancellable? cancellable;
		HardLink[] hardlinks;

		static const string ATTRIBUTES =
			FILE_ATTRIBUTE_STANDARD_NAME + "," +
			FILE_ATTRIBUTE_STANDARD_DISPLAY_NAME + "," +
			FILE_ATTRIBUTE_STANDARD_TYPE + "," +
			FILE_ATTRIBUTE_STANDARD_SIZE +  "," +
			FILE_ATTRIBUTE_UNIX_BLOCKS + "," +
			FILE_ATTRIBUTE_UNIX_NLINK + "," +
			FILE_ATTRIBUTE_UNIX_INODE + "," +
			FILE_ATTRIBUTE_UNIX_DEVICE + "," +
			FILE_ATTRIBUTE_ACCESS_CAN_READ;

		Results add_directory (File directory, FileInfo info, Gtk.TreeIter? parent_iter = null) {
			var results = Results ();
			Gtk.TreeIter iter;

			if (Application.is_excluded_location (directory)) {
				return results;
			}

			var display_name = info.get_display_name ();
			var parse_name = directory.get_parse_name ();

			append (out iter, parent_iter);
			set (iter,
			     Columns.DISPLAY_NAME, display_name,
			     Columns.PARSE_NAME,   parse_name);

			if (info.has_attribute (FILE_ATTRIBUTE_STANDARD_SIZE)) {
				results.size = info.get_size ();
			}

			if (info.has_attribute (FILE_ATTRIBUTE_UNIX_BLOCKS)) {
				results.alloc_size = 512 * info.get_attribute_uint64 (FILE_ATTRIBUTE_UNIX_BLOCKS);
			}

			results.elements = 1;

			try {
				var children = directory.enumerate_children (ATTRIBUTES, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
				FileInfo? child_info;
				while ((child_info = children.next_file (cancellable)) != null) {
					if (cancellable.is_cancelled ()) {
						break;
					}

					switch (child_info.get_file_type ()) {
						case FileType.DIRECTORY:
							var child = directory.get_child (child_info.get_name ());
							var child_results = add_directory (child, child_info, iter);

							results.size += child_results.size;
							results.alloc_size += child_results.size;
							results.elements += child_results.elements;
							results.max_depth = int.max (results.max_depth, child_results.max_depth + 1);
							break;

						case FileType.REGULAR:
							if (child_info.has_attribute (FILE_ATTRIBUTE_UNIX_NLINK)) {
								if (child_info.get_attribute_uint32 (FILE_ATTRIBUTE_UNIX_NLINK) > 1) {
									var hl = HardLink (child_info);

									/* check if we've already encountered this file */
									if (hl in hardlinks) {
										continue;
									}

									hardlinks += hl;
								}
							}

							if (child_info.has_attribute (FILE_ATTRIBUTE_UNIX_BLOCKS)) {
								results.alloc_size += 512 * child_info.get_attribute_uint64 (FILE_ATTRIBUTE_UNIX_BLOCKS);
							}
							results.size += child_info.get_size ();
							results.elements++;
							break;

						default:
							/* ignore other types (symlinks, sockets, devices, etc) */
							break;
					}
				}
			} catch (IOError.PERMISSION_DENIED e) {
			} catch (Error e) {
				warning ("couldn't iterate %s: %s", parse_name, e.message);
			}

			if (!cancellable.is_cancelled ()) {
				set (iter,
				     Columns.SIZE,       results.size,
				     Columns.ALLOC_SIZE, results.alloc_size,
				     Columns.ELEMENTS,   results.elements,
				     Columns.STATE,      State.NEED_PERCENT);
			} else {
				set (iter,
				     Columns.STATE,      State.CANCELLED);
			}

			return results;
		}

		void add_percent (uint64 parent_size, Gtk.TreeIter? parent = null) {
			Gtk.TreeIter iter;

			if (iter_children (out iter, parent)) {
				do {
					uint64 size;
					get (iter, Columns.SIZE, out size);
					set (iter,
					     Columns.PERCENT, 100 * ((double) size) / ((double) parent_size),
					     Columns.STATE,   State.DONE);
					add_percent (size, iter);
				} while (iter_next (ref iter));
			}
		}

		void scan (File directory) {
			try {
				var info = directory.query_info (ATTRIBUTES, 0, cancellable);
				var results = add_directory (directory, info);
				add_percent (results.size);
			} catch { }
		}

		public Scanner (File directory) {
			set_column_types (new Type[] {
			                  typeof (string),  /* DIR_NAME */
			                  typeof (string),  /* PARSE_NAME */
			                  typeof (double),  /* PERCENT */
			                  typeof (uint64),  /* SIZE */
			                  typeof (uint64),  /* ALLOC_SIZE */
			                  typeof (int),     /* ELEMENTS */
			                  typeof (State)}); /* STATE */
			scan (directory);
		}
	}
}
