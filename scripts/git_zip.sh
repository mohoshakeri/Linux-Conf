#!/bin/bash

# Get Current Directory Name And Convert To Uppercase
DIR_NAME=$(basename "$PWD")
ZIP_NAME=$(echo "$DIR_NAME" | tr '[:lower:]' '[:upper:]')

# Set Output Path To Downloads
OUTPUT_PATH="$HOME/Downloads/${ZIP_NAME}.zip"

# Initialize Exclude Arguments
EXCLUDES=()

# Always Exclude .git Directory
EXCLUDES+=("-x" ".git/*")

# Read .gitignore If Exists And Convert To Zip Excludes
if [ -f .gitignore ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip Empty Lines And Comments
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    # Remove Trailing Slash
    pattern="${line%/}"

    # Add Exclude Pattern
    EXCLUDES+=("-x" "$pattern")
    EXCLUDES+=("-x" "$pattern/*")
  done < .gitignore
fi

# Create Zip Archive In Downloads Folder
zip -r "$OUTPUT_PATH" . "${EXCLUDES[@]}"

# Print Result Path
echo "Zip Created At: $OUTPUT_PATH"
