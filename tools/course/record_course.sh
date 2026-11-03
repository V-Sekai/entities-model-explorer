#!/bin/sh
# Record the staged obstacle course run as two videos: a follow camera and an orbit camera (Godot's movie writer, fixed 30 fps).
#   GODOT=<editor binary> MODEL=<rigged model> OUT=<dir> sh tools/course/record_course.sh   (from the viewer project root)
# The viewer shows its loading dialog for about 8 s first; trim it: ffmpeg -i in.avi -ss 8 -c:v libx264 -crf 20 -pix_fmt yuv420p out.mp4
set -eu
OUT=${OUT:-.}
rm -f "$HOME/Library/Application Support/Godot/app_userdata/ModelExplorer/moves/$(basename "$MODEL" | sed 's/\.[^.]*$//').moves.glb"
MOVE_CRAWL=prone MOVE_STEPS=course-stages "$GODOT" --path . --write-movie "$OUT/course_follow.avi" --fixed-fps 30 -- "$MODEL" --obstacle-course --move-quit
MOVE_CRAWL=prone MOVE_STEPS=course-stages "$GODOT" --path . --write-movie "$OUT/course_orbit.avi" --fixed-fps 30 -- "$MODEL" --obstacle-course --move-quit --orbit-video
