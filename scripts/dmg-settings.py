"""Finder layout for the SlurmBar drag-to-install disk image."""

import os

format = "UDZO"
filesystem = "HFS+"
files = [os.path.abspath(defines["app"])]
symlinks = {"Applications": "/Applications"}
background = os.path.abspath(defines["background"])

window_rect = ((200, 200), (640, 360))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
icon_size = 96
text_size = 14
label_pos = "bottom"
icon_locations = {"SlurmBar.app": (170, 170), "Applications": (470, 170)}
