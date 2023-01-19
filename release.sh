#!/bin/bash

# v1.0.0
# Requirements for this script to work:
# 1. an SSH key must be stored on the remote server.
# 2. the target server should be entered in the .ssh/config (optional, but makes it easier)
#
# Before the first release, at least the following directory and file structure must be created in the target directory:
# shared/public/fileadmin/ -> the contents of the local fileadmin folder must be uploaded here.
# shared/public/typo3conf/LocalConfiguration.php -> copy of the local LocalConfiguration.php. This way different settings can be stored later on the remote server.

# Variables
LOCAL_DIR="$(pwd)"
REMOTE_USER="username"
REMOTE_HOST="domain or IP"
REMOTE_DIR="/path/to/project"
RELEASE_COUNT=4
NEW_RELEASE="release_$(date +%Y%m%d%H%M%S)"
EXCLUDES=(
    ".git"
    ".ddev"
    ".DS_Store"
    "public/fileadmin"
    "LocalConfiguration.php"
    "release.sh"
    "sync.sh"
    ".vscode"
    ".idea"
    ".editorconfig"
    ".gitignore"
    ".hosts.yaml"
    ".php-cs-fixer.php"
    "deploy.php"
)
EXCLUDE_OPTIONS=""
SHARED_FOLDERS=(
  "public/fileadmin"
)
SHARED_FILES=(
  "public/typo3conf/LocalConfiguration.php"
)

# Colors and text formatting
GREEN='\033[0;32m'
RED='\033[0;31m'
NORMAL='\033[0m'
BOLD='\033[3m'

check_command_status(){
  if [ $? -ne 0 ]; then
      printf "${RED}Error: $1 failed${NORMAL}\n"
      ssh -qT $REMOTE_USER@$REMOTE_HOST "cd $REMOTE_DIR/releases; rm -rf $NEW_RELEASE"
      exit 1
  fi
}

rollback_to_previous_release(){
  printf "${GREEN}Rollback to previous release...${NORMAL}\n"
  # Get the previous release from the releases directory
  PREVIOUS_RELEASE=$(ssh -qT $REMOTE_USER@$REMOTE_HOST "cd $REMOTE_DIR/releases; ls -r | awk 'NR==2{print}'")

  # Delete current symlink and create new symlink to previous release
  ssh -qT $REMOTE_USER@$REMOTE_HOST << EOF
    cd $REMOTE_DIR
    rm -rf current
    ln -s releases/$PREVIOUS_RELEASE current
EOF
  check_command_status "Rollback to previous release"
}

create_new_release_dir(){
  # Create new release directory on remote server
  printf "${GREEN}Creating new release directory...${NORMAL}\n"
  ssh -qT $REMOTE_USER@$REMOTE_HOST "cd $REMOTE_DIR; mkdir -p releases; cd releases; mkdir $NEW_RELEASE"
  check_command_status "Creating new release directory"
}

rsync_files(){
  # Iterate over the exclude dirs array and build the exclude options string
  for dir in "${EXCLUDES[@]}"; do
    EXCLUDE_OPTIONS="$EXCLUDE_OPTIONS --exclude=$dir"
  done
  # Rsync files to remote server
  printf "${GREEN}Rsync files to remote server...${NORMAL}\n"
  rsync -apvz $EXCLUDE_OPTIONS -e ssh --delete $LOCAL_DIR/ $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/releases/$NEW_RELEASE
  check_command_status "Rsync files"
}

delete_old_releases(){
  # Delete oldest releases on remote server
  printf "${GREEN}Delete oldest releases on remote server...${NORMAL}\n"
  ssh -qT $REMOTE_USER@$REMOTE_HOST << EOF
    cd $REMOTE_DIR/releases
    count=0
    for dir in \$(ls -r); do
      if [ \$count -ge $RELEASE_COUNT ]; then
        rm -rf \$dir
      fi
      count=\$((count+1))
    done
EOF
  check_command_status "Delete oldest releases"
}

create_folder_symlinks(){
  # Create symlinks to specified folders on remote server
  printf "${GREEN}Create symlinks to specified folders on remote server...${NORMAL}\n"
  for folder in "${SHARED_FOLDERS[@]}"; do
    IFS='/' read -ra ADDR <<< "$folder"
    remote_directory=""
    for i in "${ADDR[@]:0:${#ADDR[@]}-1}"
    do
      remote_directory="$remote_directory/$i"
    done
    ssh -qT $REMOTE_USER@$REMOTE_HOST "cd $REMOTE_DIR/releases/$NEW_RELEASE/$remote_directory; ln -s $REMOTE_DIR/shared/$folder"
    check_command_status "Creating symlink to $folder"
  done
}

create_file_symlinks(){
  # Create symlinks to specified files
  printf "${GREEN}Create symlinks to specified files...${NORMAL}\n"
  for file in "${SHARED_FILES[@]}"; do
    directory=$(dirname "$file")
    ssh -qT $REMOTE_USER@$REMOTE_HOST "cd $REMOTE_DIR/releases/$NEW_RELEASE/$directory; ln -s $REMOTE_DIR/shared/$file"
    check_command_status "Creating symlink to $file"
  done
}

fix_permissions(){
    # With some hosters (e.g. Mittwald) the permissions of the files and folders must be corrected after an upload via rsync.
    # If you don't need this, you can dectivate or remove the function call at the bottom of this file
    printf "${GREEN}Set file permissions...${NORMAL}\n"
    ssh -qT $REMOTE_USER@$REMOTE_HOST "find $REMOTE_DIR/releases/$NEW_RELEASE/public -type f -exec chmod 644 {} \;"
    check_command_status "Setting the file permissions"
    printf "${GREEN}Set directory permissions...${NORMAL}\n"
    ssh -qT $REMOTE_USER@$REMOTE_HOST "find $REMOTE_DIR/releases/$NEW_RELEASE/public -type d -exec chmod 755 {} \;"
    check_command_status "Setting der directory permissions"
}

typo3_tasks(){
  # Clear and warmup cache via typo3 console
  printf "${GREEN}Clear and warmup cache via typo3 console...${NORMAL}\n"
  ssh -qT $REMOTE_USER@$REMOTE_HOST << EOF
    cd $REMOTE_DIR/releases/$NEW_RELEASE
    vendor/bin/typo3cms install:fixfolderstructure
    vendor/bin/typo3cms cache:flush
    vendor/bin/typo3cms cache:warmup
EOF
  check_command_status "Clear and warmup cache via typo3 console"
}

create_current_symlink(){
  # Create symlink to current release on remote server
  printf "${GREEN}Create symlink to current release on remote server...${NORMAL}\n"
  ssh -qT $REMOTE_USER@$REMOTE_HOST << EOF
    cd $REMOTE_DIR
    rm -rf current
    ln -s releases/$NEW_RELEASE current
EOF
  check_command_status "Creating symlink to current release"
}

success_message(){
    printf "${GREEN}---> The deployment was executed successfully!${NORMAL}\n"
}

if [[ "$1" == "rollback" ]]; then
  rollback_to_previous_release
else
  create_new_release_dir
  rsync_files
  create_folder_symlinks
  create_file_symlinks
  fix_permissions
  typo3_tasks
  create_current_symlink
  delete_old_releases
  success_message
fi
