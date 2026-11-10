#!/bin/sh
# Shares the toolbox image between the jobs of one workflow run, so it is pulled or built once.
#   toolbox-image.sh save <file>   # make sure the image for the current inputs exists, then save it to <file>
#   toolbox-image.sh load <file>   # load <file> so toolbox/run finds localhost/monolith-toolbox:<inputs> locally
# Runs on the host, with the engine toolbox/run picks (MONOLITH_ENGINE, else podman, else docker).
set -eu

die() { echo "toolbox-image: $*" >&2; exit 2; }

[ $# -eq 2 ] || die "usage: toolbox-image.sh save|load <file>"
cmd=$1
file=$2

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(git -C "$here" rev-parse --show-toplevel) || die "not inside a git checkout"

engine=${MONOLITH_ENGINE:-}
if [ -z "$engine" ]; then
	if command -v podman >/dev/null 2>&1; then engine=podman
	elif command -v docker >/dev/null 2>&1; then engine=docker
	else die "neither podman nor docker is installed"; fi
fi
eng=$engine
if [ "$engine" = podman ] && [ ! -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; then
	eng="podman --cgroup-manager=cgroupfs"
fi

inputs=$(cd "$root/toolbox" && cat Containerfile selfcheck | sha256sum | cut -c1-12)
image=localhost/monolith-toolbox:$inputs

case $cmd in
save)
	# Pulls or builds the image, with toolbox/run's notice, when there is none for these inputs.
	(cd "$root" && TOOLBOX= toolbox/run -- true) >&2
	mkdir -p "$(dirname "$file")"
	rm -f "$file"
	# shellcheck disable=SC2086 # $eng is a word list
	$eng save -o "$file" "$image"
	echo "toolbox-image: saved $image to $file" >&2
	;;
load)
	[ -f "$file" ] || die "$file does not exist"
	# shellcheck disable=SC2086
	$eng load -i "$file" >&2
	# shellcheck disable=SC2086
	$eng image inspect "$image" >/dev/null || die "$file does not hold $image"
	echo "toolbox-image: loaded $image from $file" >&2
	;;
*) die "unknown command $cmd" ;;
esac
