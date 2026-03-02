#!/bin/bash
# Tool Executor Component for Ralph - Specific Parsing
# Handles extraction and execution of tool calls from LLM output

# Helper to validate and canonicalize path within project root
is_path_safe() {
    local requested_path="$1"
    local project_root=$(realpath ".")
    
    # Expand user home if present
    if [[ "$requested_path" == "~"* ]]; then
        requested_path="${requested_path/#\~/$HOME}"
    fi
    
    local canonical_path
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS realpath doesn't always support -m
        canonical_path=$(python3 -c "import os; print(os.path.realpath('$requested_path'))" 2>/dev/null || realpath "$requested_path" 2>/dev/null)
    else
        canonical_path=$(realpath -m "$requested_path" 2>/dev/null)
    fi
    
    if [[ -z "$canonical_path" ]]; then
        return 1
    fi
    
    if [[ "$canonical_path" == "$project_root"* ]]; then
        echo "$canonical_path"
        return 0
    else
        return 1
    fi
}

# Execute a tool call
execute_tool() {
    local tool_name="$1"
    local content="$2"

    log_status "INFO" "🛠 Executing tool: $tool_name"
    
    case "$tool_name" in
        "read_file")
            local raw_path=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="path">(.*?)<\/arg>/s')
            local safe_path=$(is_path_safe "$raw_path")
            if [[ $? -eq 0 ]]; then
                if [[ -f "$safe_path" ]]; then
                    echo "--- TOOL RESULT ($tool_name) ---"
                    cat "$safe_path"
                    echo "-------------------------------"
                else
                    echo "Error: File not found: $raw_path"
                fi
            else
                echo "Error: Path traversal attempt blocked: $raw_path"
            fi
            ;;
        "write_file")
            local raw_path=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="path">(.*?)<\/arg>/s')
            local file_content=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="content">(.*?)<\/arg>/s')
            
            local safe_path=$(is_path_safe "$raw_path")
            if [[ $? -eq 0 ]]; then
                mkdir -p "$(dirname "$safe_path")"
                echo "$file_content" > "$safe_path"
                echo "--- TOOL RESULT ($tool_name) ---"
                echo "Successfully wrote to $raw_path"
                echo "-------------------------------"
            else
                echo "Error: Path traversal attempt blocked: $raw_path"
            fi
            ;;
        "run_command")
            local cmd=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="command">(.*?)<\/arg>/s')
            if [[ -n "$cmd" ]]; then
                # Strict allowlist of safe base commands
                local first_token=$(echo "$cmd" | awk '{print $1}')
                local ALLOWED_COMMANDS=("ls" "pwd" "date" "grep" "cat" "echo" "git" "npm" "pytest" "bats" "python" "python3" "node" "go" "cargo" "find")
                
                local is_allowed=false
                for allowed in "${ALLOWED_COMMANDS[@]}"; do
                    if [[ "$first_token" == "$allowed" ]]; then
                        is_allowed=true
                        break
                    fi
                done
                
                if [[ "$is_allowed" == "true" ]]; then
                    echo "--- TOOL RESULT ($tool_name) ---"
                    # Note: Ideally this should run in a sandbox like firejail or docker
                    bash -c "$cmd" 2>&1
                    echo "-------------------------------"
                else
                    echo "Error: Command not allowed: $first_token (must be one of: ${ALLOWED_COMMANDS[*]})"
                fi
            else
                echo "Error: Missing command for run_command"
            fi
            ;;
        "list_files")
            local raw_dir=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="directory">(.*?)<\/arg>/s')
            raw_dir=${raw_dir:-"."}
            local safe_dir=$(is_path_safe "$raw_dir")
            if [[ $? -eq 0 ]]; then
                echo "--- TOOL RESULT ($tool_name) ---"
                ls -R "$safe_dir"
                echo "-------------------------------"
            else
                echo "Error: Path traversal attempt blocked: $raw_dir"
            fi
            ;;
        *)
            echo "Error: Unknown tool: $tool_name"
            ;;
    esac
}

# Process AI response for tool calls
run_tools_if_requested() {
    local input_file="$1"
    local results_file
    results_file=$(mktemp) || { log_status "ERROR" "Failed to create temp file"; return 1; }
    
    local found_tools=false
    local temp_blocks_dir
    temp_blocks_dir=$(mktemp -d) || { log_status "ERROR" "Failed to create temp directory"; rm -f "$results_file"; return 1; }
    
    # Use perl to extract each tool_call block
    perl -0777 -ne 'my $i=0; while (/<tool_call(.*?)<\/tool_call>/sg) { open my $fh, ">", "'$temp_blocks_dir'/block_$i.txt"; print $fh "<tool_call$1</tool_call>"; close $fh; $i++; }' "$input_file"
    
    for block_file in "$temp_blocks_dir"/block_*.txt; do
        if [[ -f "$block_file" ]]; then
            found_tools=true
            local block_content=$(cat "$block_file")
            # Extract tool name from the first line of the block
            local tool_name=$(echo "$block_content" | head -n 1 | sed -n 's/.*<tool_call name="\([^"]*\)".*/\1/p')
            execute_tool "$tool_name" "$block_content" >> "$results_file"
        fi
    done
    
    rm -rf "$temp_blocks_dir"
    
    if [[ "$found_tools" == "true" ]]; then
        cat "$results_file"
        rm "$results_file"
        return 0
    else
        rm "$results_file"
        return 1
    fi
}