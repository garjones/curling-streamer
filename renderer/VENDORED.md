These files are vendored VERBATIM from `counter/renderer/` (the live
scoreboard repo, github.com/garjones/curling-counter). counter owns them;
do not edit here. To update: re-copy from counter and note the commit.
The contract the compositor relies on: `bug-NN.fifo` in the FIFO dir,
640x360 raw RGBA at ~1 fps, writer repeats the latest frame and reopens
on BrokenPipeError.
