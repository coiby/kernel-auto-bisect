#!/bin/bash
#
# kab.sh:  kernel-auto-bisect (kab)
#
# Uses CRIU (Checkpoint Restore in Userspace) to restore the process for reboot or kernel panic
#
source /usr/local/bin/kernel-auto-bisect/lib.sh

safe_cd() {
	cd "$1" || {
		echo "Failed to cd $1"
		exit 1
	}
}

do_start() {
	initialize
	verify_intial_commits
	log "Starting git bisect process"
	git bisect start "$BAD_REF" "$GOOD_REF"

	main_bisect_loop
}

should_continue_bisect() {
	safe_cd "$GIT_REPO"
	! git bisect log | grep -q "first bad commit"
}

main_bisect_loop() {
	while should_continue_bisect; do
		local commit=$(get_current_commit)
		log "--- Testing bisect commit: $commit ---"

		if commit_good "$commit"; then
			log "Marking $commit as GOOD"
			git bisect good "$commit"
		else
			log "Marking $commit as BAD"
			git bisect bad "$commit"
		fi
	done
	generate_final_report
}

do_start
