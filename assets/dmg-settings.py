# dmgbuild settings for the DS3Bridge disk image (used by ./build.sh --release).
# Values passed with -D: app, background, icon.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]                    # volume icon while the image is mounted
background = defines["background"]        # 640x400, with a @2x version (TIFF)

window_rect = ((200, 140), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (170, 200),
    "Applications": (470, 200),
}
hide_extension = [app_name]
