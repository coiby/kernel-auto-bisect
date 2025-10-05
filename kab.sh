#!/bin/bash
#
# kab.sh:  kernel-auto-bisect (kab)
#
# Uses CRIU (Checkpoint Restore in Userspace) to restore the process for reboot or kernel panic
#
source /usr/local/bin/kernel-auto-bisect/lib.sh

# --- Main Bisection Functions ---
do_start() {
	# Clean up any previous CRIU state
	rm -rf "$RPM_FAKE_REPO_PATH"
	touch "$LOG_FILE"

	log "--- Bisection START ---"

	initialize

	verify_intial_commits

	# Start git bisect
	log "Starting git bisect process"
	git bisect start "$BAD_REF" "$GOOD_REF"

	# Check for adjacent commits (no bisection needed)
	if [[ $(git rev-list ${GOOD_REF}..${BAD_REF} | wc -l) -eq 1 ]]; then
		log "--- BISECTION FINISHED (Adjacent commits) ---"
		generate_final_report "$BAD_REF"
		do_abort "Bisection Complete"
	fi

	# Start main bisection loop
	main_bisect_loop
}

should_continue_bisect() {
	local repo_dir
	if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi
	cd "$repo_dir"

	# Check if git bisect is still ongoing
	git bisect log >/dev/null 2>&1
}

main_bisect_loop() {
	local repo_dir
	if [[ "$INSTALL_STRATEGY" == "rpm" ]]; then repo_dir="$RPM_FAKE_REPO_PATH"; else repo_dir="$KERNEL_SRC_DIR"; fi
	cd "$repo_dir"

	while should_continue_bisect; do
		local commit=$(get_current_commit)
		log "--- Testing bisect commit: $commit ---"

		if commit_good "$commit"; then
			log "Marking commit as GOOD"
			local bisect_output=$(git bisect good "$commit")
		else
			log "Marking commit as BAD"
			local bisect_output=$(git bisect bad "$commit")
		fi

		echo "$bisect_output"

		# Check if bisection is complete
		if echo "$bisect_output" | grep -q "is the first bad commit"; then
			log "--- BISECTION FINISHED ---"
			generate_final_report "$commit"
			finish
			return
		fi
	done

	log "Bisection loop ended unexpectedly"
	do_abort "Bisection incomplete"
}

# Start bisection - CRIU daemon handles any necessary restoration automatically
do_start
