#!/bin/bash

Describe 'kdump-lib'
	Include ./lib.sh
	KAB_SPEC_TEST_RUN_DIR=$(mktemp -u /tmp/spec_test.XXXXXXXXXX)

	Describe "run_cmd"
		out=hello
		It "should handle cwd with a empty space corrently"
			_dir_spac=${KAB_SPEC_TEST_RUN_DIR}/"a b"
			mkdir -p "$_dir_spac"
			When call run_cmd -cwd "$_dir_spac" echo "$out"
			The output should equal $out
		End

		It "should handle a command with && correctly"
			out1="hi"
			_dir_spac=${KAB_SPEC_TEST_RUN_DIR}/"a b"
			mkdir -p "$_dir_spac"
			When call run_cmd -cwd "$_dir_spac" echo "$out1" "&&" echo "$out"
			The output should include "$out1"
			The output should include "$out"
		End
	End
End
