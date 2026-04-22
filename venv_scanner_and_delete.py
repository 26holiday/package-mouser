#!/usr/bin/env python3
"""
Script to find .venv, venv, and node_modules directories and calculate their sizes.
Works on Windows, Linux, and macOS. Includes deletion functionality.
"""

import os
import sys
from pathlib import Path
import argparse
from typing import List, Tuple
import time
import shutil

def get_folder_size(folder_path: Path) -> int:
    """Calculate the total size of a folder in bytes."""
    total_size = 0
    try:
        for dirpath, dirnames, filenames in os.walk(folder_path):
            for filename in filenames:
                file_path = Path(dirpath) / filename
                try:
                    if file_path.exists():
                        total_size += file_path.stat().st_size
                except (OSError, IOError):
                    # Skip files that can't be accessed (permissions, etc.)
                    continue
    except (OSError, IOError):
        # Skip directories that can't be accessed
        pass
    return total_size

def format_size(size_bytes: int) -> str:
    """Convert bytes to human readable format."""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.2f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.2f} PB"

def should_skip_directory(dir_path: Path) -> bool:
    """Check if directory should be skipped (system directories, etc.)."""
    skip_patterns = [
        'System Volume Information',
        '$RECYCLE.BIN',
        'Windows',
        'Program Files',
        'Program Files (x86)',
        'ProgramData',
        '.git',
        '__pycache__',
    ]
    
    dir_name = dir_path.name
    return any(pattern.lower() in dir_name.lower() for pattern in skip_patterns)

def delete_directory(dir_path: Path) -> bool:
    """
    Delete a directory and all its contents.
    Returns True if successful, False otherwise.
    """
    try:
        print(f"Deleting: {dir_path}")
        shutil.rmtree(dir_path)
        return True
    except (OSError, PermissionError) as e:
        print(f"Error deleting {dir_path}: {e}")
        return False

def confirm_deletion(found_dirs: List[Tuple[Path, str, int]]) -> bool:
    """Ask user for confirmation before deletion."""
    total_size = sum(size for _, _, size in found_dirs)
    
    print(f"\n⚠️  WARNING: This will DELETE {len(found_dirs)} directories!")
    print(f"Total size to be deleted: {format_size(total_size)}")
    print("\nDirectories to be deleted:")
    print("-" * 60)
    
    for dir_path, dir_type, size in found_dirs:
        print(f"{dir_type:12} | {format_size(size):>10} | {dir_path}")
    
    print("-" * 60)
    print("This action CANNOT be undone!")
    
    while True:
        response = input("\nAre you sure you want to delete these directories? (yes/no): ").lower().strip()
        if response in ['yes', 'y']:
            return True
        elif response in ['no', 'n']:
            return False
        else:
            print("Please enter 'yes' or 'no'")

def interactive_deletion(found_dirs: List[Tuple[Path, str, int]]) -> List[Path]:
    """Allow user to select which directories to delete."""
    if not found_dirs:
        return []
    
    print(f"\nFound {len(found_dirs)} directories. Select which ones to delete:")
    print("-" * 80)
    
    for i, (dir_path, dir_type, size) in enumerate(found_dirs, 1):
        print(f"{i:2}. {dir_type:12} | {format_size(size):>10} | {dir_path}")
    
    print("-" * 80)
    print("Enter the numbers of directories to delete (e.g., '1,3,5' or '1-5' or 'all'):")
    print("Press Enter without input to cancel")
    
    while True:
        selection = input("Selection: ").strip()
        
        if not selection:
            return []
        
        try:
            selected_dirs = []
            
            if selection.lower() == 'all':
                selected_dirs = [dir_path for dir_path, _, _ in found_dirs]
            else:
                indices = set()
                for part in selection.split(','):
                    part = part.strip()
                    if '-' in part:
                        start, end = map(int, part.split('-'))
                        indices.update(range(start, end + 1))
                    else:
                        indices.add(int(part))
                
                for idx in indices:
                    if 1 <= idx <= len(found_dirs):
                        selected_dirs.append(found_dirs[idx - 1][0])
                    else:
                        print(f"Invalid index: {idx}")
                        continue
            
            if selected_dirs:
                # Show selection for confirmation
                selected_items = [(path, dtype, size) for path, dtype, size in found_dirs if path in selected_dirs]
                total_size = sum(size for _, _, size in selected_items)
                
                print(f"\nSelected {len(selected_dirs)} directories for deletion:")
                print(f"Total size: {format_size(total_size)}")
                
                confirm = input("Confirm deletion? (yes/no): ").lower().strip()
                if confirm in ['yes', 'y']:
                    return selected_dirs
                else:
                    print("Deletion cancelled.")
                    return []
            else:
                return []
                
        except ValueError:
            print("Invalid input format. Use numbers separated by commas, ranges (1-5), or 'all'")
            continue

def find_venv_and_node_modules(root_path: Path, max_depth: int = None) -> List[Tuple[Path, str, int]]:
    """
    Find all .venv, venv, and node_modules directories.
    Returns list of tuples: (path, type, size_in_bytes)
    """
    found_dirs = []
    target_names = {'.venv', 'venv', 'node_modules'}
    
    def scan_directory(current_path: Path, current_depth: int = 0):
        if max_depth is not None and current_depth > max_depth:
            return
            
        try:
            if not current_path.is_dir() or should_skip_directory(current_path):
                return
                
            # Check if current directory matches our targets
            if current_path.name in target_names:
                print(f"Found: {current_path}")  # Progress indicator
                size = get_folder_size(current_path)
                folder_type = "Python venv" if current_path.name in {'.venv', 'venv'} else "Node modules"
                found_dirs.append((current_path, folder_type, size))
                return  # Don't scan inside venv/node_modules
            
            # Scan subdirectories
            try:
                for item in current_path.iterdir():
                    if item.is_dir():
                        scan_directory(item, current_depth + 1)
            except (PermissionError, OSError):
                # Skip directories we can't access
                pass
                
        except (PermissionError, OSError):
            # Skip directories we can't access
            pass
    
    print(f"Scanning {root_path}...")
    scan_directory(root_path)
    return found_dirs

def main():
    parser = argparse.ArgumentParser(
        description="Find virtual environments (.venv, venv) and node_modules directories"
    )
    parser.add_argument(
        "path", 
        nargs="?", 
        default=".",
        help="Root path to scan (default: current directory)"
    )
    parser.add_argument(
        "--depth", 
        "-d", 
        type=int, 
        help="Maximum depth to scan (default: unlimited)"
    )
    parser.add_argument(
        "--sort-by-size", 
        "-s", 
        action="store_true", 
        help="Sort results by size (largest first)"
    )
    parser.add_argument(
        "--delete",
        action="store_true",
        help="Delete all found directories after confirmation"
    )
    parser.add_argument(
        "--interactive",
        "-i",
        action="store_true", 
        help="Interactively select which directories to delete"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be deleted without actually deleting"
    )
    
    args = parser.parse_args()
    
    root_path = Path(args.path).resolve()
    
    if not root_path.exists():
        print(f"Error: Path '{root_path}' does not exist.")
        sys.exit(1)
    
    if not root_path.is_dir():
        print(f"Error: Path '{root_path}' is not a directory.")
        sys.exit(1)
    
    print(f"Scanning for .venv, venv, and node_modules directories...")
    print(f"Root path: {root_path}")
    if args.depth:
        print(f"Max depth: {args.depth}")
    print("-" * 60)
    
    start_time = time.time()
    found_dirs = find_venv_and_node_modules(root_path, args.depth)
    end_time = time.time()
    
    if not found_dirs:
        print("No virtual environments or node_modules directories found.")
        return
    
    # Sort results
    if args.sort_by_size:
        found_dirs.sort(key=lambda x: x[2], reverse=True)
    else:
        found_dirs.sort(key=lambda x: str(x[0]))
    
    print(f"\nFound {len(found_dirs)} directories:")
    print("-" * 60)
    
    total_size = 0
    for dir_path, dir_type, size in found_dirs:
        total_size += size
        print(f"{dir_type:12} | {format_size(size):>10} | {dir_path}")
    
    print("-" * 60)
    print(f"Total size: {format_size(total_size)}")
    print(f"Scan completed in {end_time - start_time:.2f} seconds")
    
    # Summary by type
    python_dirs = [d for d in found_dirs if d[1] == "Python venv"]
    node_dirs = [d for d in found_dirs if d[1] == "Node modules"]
    
    if python_dirs:
        python_size = sum(d[2] for d in python_dirs)
        print(f"\nPython virtual environments: {len(python_dirs)} directories, {format_size(python_size)}")
    
    if node_dirs:
        node_size = sum(d[2] for d in node_dirs)
        print(f"Node.js modules: {len(node_dirs)} directories, {format_size(node_size)}")
    
    # Handle deletion options
    if args.dry_run:
        print(f"\n🔍 DRY RUN: Would delete {len(found_dirs)} directories ({format_size(total_size)})")
        return
    
    if args.delete or args.interactive:
        if not found_dirs:
            print("Nothing to delete.")
            return
            
        dirs_to_delete = []
        
        if args.interactive:
            dirs_to_delete = interactive_deletion(found_dirs)
        elif args.delete:
            if confirm_deletion(found_dirs):
                dirs_to_delete = [dir_path for dir_path, _, _ in found_dirs]
        
        if dirs_to_delete:
            print(f"\nDeleting {len(dirs_to_delete)} directories...")
            print("-" * 60)
            
            successful_deletions = 0
            failed_deletions = 0
            total_deleted_size = 0
            
            for dir_path in dirs_to_delete:
                # Find the size of this directory
                dir_size = next(size for path, _, size in found_dirs if path == dir_path)
                
                if delete_directory(dir_path):
                    successful_deletions += 1
                    total_deleted_size += dir_size
                else:
                    failed_deletions += 1
            
            print("-" * 60)
            print(f"✅ Successfully deleted: {successful_deletions} directories")
            if failed_deletions > 0:
                print(f"❌ Failed to delete: {failed_deletions} directories")
            print(f"💾 Total space freed: {format_size(total_deleted_size)}")
        else:
            print("No directories were deleted.")

if __name__ == "__main__":
    main()