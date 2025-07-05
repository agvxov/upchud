#!/usr/bin/env bash

TCL_SCRIPT="./upchud.tcl"
TEST_FILE="example.png"
#TEST_FILE="example.txt"
TCLSH_CMD="$(command -v tclsh)"

# verify files exist
if [[ ! -x "$TCL_SCRIPT" ]]; then
  echo "ERROR: cannot execute $TCL_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$TEST_FILE" ]]; then
  echo "ERROR: test file $TEST_FILE not found" >&2
  exit 1
fi

CONTENT_LENGTH=$(wc -c < "$TEST_FILE")
export CONTENT_LENGTH

export HTTP_CONTENT_DISPOSITION="form-data; name=\"file\"; filename=\"$TEST_FILE\""

echo "Uploading '$TEST_FILE' ($CONTENT_LENGTH bytes) to $TCL_SCRIPT"
OUT_NAME=$("$TCLSH_CMD" "$TCL_SCRIPT" < "$TEST_FILE")

echo "Script response:\n $OUT_NAME"
