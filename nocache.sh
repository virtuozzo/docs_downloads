#!/bin/bash
#
# The script runs provided command in a separate memory cgroup with
# limited pagecache. Using this wrapper for programs which generate a
# lot of knowingly useless pagecache results in better overall Node
# performance and better Node responsiveness.
#
# Especially useful when running self written backups or other processes
# which generate a lot of pagecache which won't be used later by other
# processes.
#
# Usage: nocache.sh				\
#		[-limit LIMIT]			\
#		[-pcgroup PARENT_CGROUP]	\
#		<command with options>
#
# -limit LIMIT
#	The pagecache limit (in MB) to apply to the process.
#	Default: 256MB
#
# -pcgroup PARENT_CGROUP
#	Define a parent memory cgroup - where a cgroup with limited
#	pagecache to be created.
#	Default: current memory cgroup is used as the parent one.
#
# Examples:
#	# nocache.sh backup_script.sh
#	# nocache.sh 				\
#		-limit 128			\
#		-pcgroup /machine.slice		\
#		backup_script.sh
#
#
# Author: Konstantin Khorenko <khorenko@virtuozzo.com>
#
# Copyright (c) 2020 Virtuozzo International GmbH. All rights reserved.
#

set -e

LIMIT=268435456		# default pagecache limit 256MB
PCGROUP=""		# current memcg will be taken as a parent by default


function usage
{
	cat << EOF
Usage: nocache.sh				\\
		[-limit LIMIT]			\\
		[-pcgroup PARENT_CGROUP]	\\
		<command with options>

-limit LIMIT
	The pagecache limit (in MB) to apply to the process.
	Default: 256MB.

-pcgroup PARENT_CGROUP
	Define a parent memory cgroup - where a cgroup with limited
	pagecache to be created.
	Default: current memory cgroup is used as the parent one.

Examples:
	# nocache.sh backup_script.sh
	# nocache.sh				\\
		-limit 128			\\
		-pcgroup /machine.slice		\\
		backup_script.sh
EOF
}

function usage_exit
{
	usage
	exit 1
}

function sigint_handler
{
	# remove pagecache limited cgroup on Ctrl-C
	echo $$ >> "/sys/fs/cgroup/memory/$PCGROUP/tasks"
	rmdir "$CGPATH"
}

[[ $# -eq 0 ]] && usage_exit

# parse wrapper options
while [[ $# -gt 0 ]]; do
	case $1 in
	    -limit)
		shift		# "-limit"
		[[ $# -eq 0 ]] && usage_exit

		LIMIT=$(($1*1024*1024))	# argument in MB
		shift		# limit value
		;;

	    -pcgroup)
		shift		# "-pcgroup"
		[[ $# -eq 0 ]] && usage_exit

		PCGROUP="$1"
		shift		# parent cgroup path
		;;

	    *)  # we've parsed all options already
		break
		;;
	esac
done

# if not provided use current memcg as the "parent" cgroup
if [ -z "$PCGROUP" ]; then
	PCGROUP="$(cat /proc/self/cgroup  | grep "memory:" | head -n 1 | \
		   cut -f 3 --delimiter=':')"
fi

# pagecache_limit.$$ - is the leaf name of pagecache limited cgroup,
# where $$ - if the pid of the wrapper
CGPATH="/sys/fs/cgroup/memory/$PCGROUP/pagecache_limit.$$"

trap 'sigint_handler' INT

# Do the magic:
# - create a separate cgroup
# - disable tcache for it
# - limit the pagecache for it
# - put "self" process into it (children processes inherit cgroups)
mkdir "$CGPATH"
echo 1		> "$CGPATH/memory.disable_cleancache"
echo $LIMIT	> "$CGPATH/memory.cache.limit_in_bytes"
echo $$		> "$CGPATH/tasks"

set +e
# run the provided command line with arguments
$@
# save its exit code, the wrapper will exit with the same code,
# can be used for health monitoring/errors handling
RET=$?
set -e

# cleanup - remove pagecache limited cgroup
echo $$ >> "/sys/fs/cgroup/memory/$PCGROUP/tasks"
[[ -d "$CGPATH" ]] && rmdir "$CGPATH"

exit $RET