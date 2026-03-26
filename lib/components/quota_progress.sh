#!/bin/bash

# ============================================================================
# Claude Code Statusline - Enterprise Quota Progress Bar Component
# ============================================================================
#
# Displays Claude Enterprise account quota usage as a visual progress bar.
# Reads monthly spending from cost module and compares against configured quota.
#
# Display Format: Quota: [████████░░░░░░░░] 45% $90.00/$200.00
#
# Color Thresholds:
#   - Green:  0-50%  (comfortable)
#   - Yellow: 50-80% (caution)
#   - Red:    80%+   (critical)
#
# Dependencies: cost.sh, display.sh, themes.sh
# ============================================================================

# Component data storage
COMPONENT_QUOTA_USED=""
COMPONENT_QUOTA_LIMIT=""
COMPONENT_QUOTA_PERCENTAGE=""
COMPONENT_QUOTA_EXPIRY=""

# ============================================================================
# PROGRESS BAR RENDERING
# ============================================================================

# Render a progress bar with configurable width and fill characters
# Args: percentage (0-100), width (default 20), fill_char, empty_char
render_progress_bar() {
    local percentage="${1:-0}"
    local width="${2:-20}"
    local fill_char="${3:-█}"
    local empty_char="${4:-░}"

    # Clamp percentage to 0-100
    if [[ "$percentage" -lt 0 ]]; then
        percentage=0
    elif [[ "$percentage" -gt 100 ]]; then
        percentage=100
    fi

    # Calculate filled and empty portions
    local filled=$(( (percentage * width + 50) / 100 ))
    local empty=$((width - filled))

    # Build the bar
    local bar=""
    for ((i = 0; i < filled; i++)); do
        bar="${bar}${fill_char}"
    done
    for ((i = 0; i < empty; i++)); do
        bar="${bar}${empty_char}"
    done

    echo "$bar"
}

# ============================================================================
# COMPONENT DATA COLLECTION
# ============================================================================

# Fetch quota data from Anthropic OAuth API (extra_usage object)
# API returns cents: monthly_limit=20000 ($200), used_credits=15095 ($150.95)
# Also returns pre-calculated utilization percentage
# Caches full JSON blob with 5-minute TTL (same as usage_limits)
fetch_quota_from_api() {
    local token
    if type get_claude_oauth_token &>/dev/null; then
        token=$(get_claude_oauth_token)
    else
        if [[ "$(uname -s)" == "Darwin" ]]; then
            token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null)
        fi
    fi

    if [[ -z "$token" ]]; then
        echo ""
        return 1
    fi

    local cache_dir="${CACHE_BASE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-statusline}"
    [[ -d "$cache_dir" ]] || mkdir -p "$cache_dir" 2>/dev/null
    local cache_file="${cache_dir}/quota_data_global.cache"
    local now
    now=$(date +%s)

    # Check cache (1-minute TTL)
    if [[ -f "$cache_file" ]]; then
        local cache_mtime cache_age
        if [[ "$(uname -s)" == "Darwin" ]]; then
            cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null || echo 0)
        else
            cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        fi
        cache_age=$((now - cache_mtime))
        if [[ "$cache_age" -lt 60 ]]; then
            cat "$cache_file" 2>/dev/null
            return 0
        fi
    fi

    local response
    response=$(curl -s --max-time 3 \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

    if [[ -n "$response" ]]; then
        local is_enabled
        is_enabled=$(echo "$response" | jq -r '.extra_usage.is_enabled // empty' 2>/dev/null)
        if [[ "$is_enabled" == "true" ]]; then
            local quota_json
            quota_json=$(echo "$response" | jq -c '.extra_usage' 2>/dev/null)
            echo "$quota_json" > "$cache_file" 2>/dev/null
            debug_log "quota_progress: fetched fresh quota data from API" "INFO"
            echo "$quota_json"
            return 0
        fi
    fi

    # Return stale cache if available
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    echo ""
    return 1
}

# Collect quota data — API-first with config fallback
collect_quota_progress_data() {
    debug_log "Collecting quota_progress component data" "INFO"

    COMPONENT_QUOTA_LIMIT="0.00"
    COMPONENT_QUOTA_USED="0.00"
    COMPONENT_QUOTA_PERCENTAGE=0
    COMPONENT_QUOTA_EXPIRY=""

    # Priority 1: Anthropic OAuth API (extra_usage — cents to dollars)
    local api_data
    api_data=$(fetch_quota_from_api 2>/dev/null)

    if [[ -n "$api_data" ]]; then
        local limit_cents used_cents utilization
        limit_cents=$(echo "$api_data" | jq -r '.monthly_limit // empty' 2>/dev/null)
        used_cents=$(echo "$api_data" | jq -r '.used_credits // empty' 2>/dev/null)
        utilization=$(echo "$api_data" | jq -r '.utilization // empty' 2>/dev/null)

        if [[ -n "$limit_cents" && "$limit_cents" != "null" && "$limit_cents" != "0" ]]; then
            # Convert cents to dollars
            COMPONENT_QUOTA_LIMIT=$(echo "scale=2; $limit_cents / 100" | bc 2>/dev/null || printf "%.2f" "$(echo "$limit_cents * 0.01" | bc 2>/dev/null)")
            COMPONENT_QUOTA_USED=$(echo "scale=2; ${used_cents:-0} / 100" | bc 2>/dev/null || printf "%.2f" "$(echo "${used_cents:-0} * 0.01" | bc 2>/dev/null)")

            # Use API-provided utilization (already a percentage)
            if [[ -n "$utilization" && "$utilization" != "null" ]]; then
                COMPONENT_QUOTA_PERCENTAGE=$(printf "%.0f" "$utilization" 2>/dev/null || echo "0")
            fi

            debug_log "quota_progress API: limit=\$$COMPONENT_QUOTA_LIMIT used=\$$COMPONENT_QUOTA_USED pct=$COMPONENT_QUOTA_PERCENTAGE%" "INFO"
        fi
    fi

    # Priority 2: Config fallback (manual quota + cost module for usage)
    if [[ "$COMPONENT_QUOTA_LIMIT" == "0.00" ]]; then
        COMPONENT_QUOTA_LIMIT="${ENV_CONFIG_QUOTA_MONTHLY_LIMIT:-${CONFIG_QUOTA_MONTHLY_LIMIT:-200.00}}"

        if is_module_loaded "cost"; then
            local usage_info
            usage_info=$(get_claude_usage_info)
            if [[ -n "$usage_info" ]]; then
                local remaining="$usage_info"
                remaining="${remaining#*:}"
                local month_cost="${remaining%%:*}"
                if [[ -n "$month_cost" && "$month_cost" != "-.--" ]]; then
                    COMPONENT_QUOTA_USED="$month_cost"
                fi
            fi
        fi

        # Calculate percentage from config values
        if [[ "$COMPONENT_QUOTA_LIMIT" != "0" && "$COMPONENT_QUOTA_LIMIT" != "0.00" ]]; then
            local used_c limit_c
            used_c=$(printf "%.0f" "$(echo "$COMPONENT_QUOTA_USED * 100" | bc 2>/dev/null || echo "0")")
            limit_c=$(printf "%.0f" "$(echo "$COMPONENT_QUOTA_LIMIT * 100" | bc 2>/dev/null || echo "20000")")
            if [[ "$limit_c" -gt 0 ]]; then
                COMPONENT_QUOTA_PERCENTAGE=$(( (used_c * 100 + limit_c / 2) / limit_c ))
            fi
        fi

        debug_log "quota_progress config: limit=\$$COMPONENT_QUOTA_LIMIT used=\$$COMPONENT_QUOTA_USED pct=$COMPONENT_QUOTA_PERCENTAGE%" "INFO"
    fi

    # Calculate quota expiry estimate from burn rate (shared for both paths)
    # Primary: realtime 5h burn rate (get_cached_native_burn_rate)
    # Fallback: today's cost / hours elapsed today (always available from JSONL)
    local cost_per_hour=""

    # Fallback: daily average rate from JSONL (no OAuth API dependency)
    if is_module_loaded "cost" && declare -f get_claude_usage_info &>/dev/null; then
        local usage_info today_cost
        usage_info=$(get_claude_usage_info 2>/dev/null)
        if [[ -n "$usage_info" ]]; then
            # Format: session:month:week:today:block:reset
            today_cost=$(echo "$usage_info" | cut -d: -f4)
            if [[ -n "$today_cost" ]] && awk -v c="$today_cost" 'BEGIN{exit !(c+0 > 0)}' 2>/dev/null; then
                local today_start_epoch now_epoch hours_elapsed
                if [[ "$(uname -s)" == "Darwin" ]]; then
                    today_start_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" "+%s" 2>/dev/null)
                else
                    today_start_epoch=$(date -d "$(date +%Y-%m-%d)" "+%s" 2>/dev/null)
                fi
                now_epoch=$(date +%s)
                hours_elapsed=$(awk -v s="$today_start_epoch" -v n="$now_epoch" \
                    'BEGIN { h=(n-s)/3600; if(h<1) h=1; printf "%.2f", h }')
                cost_per_hour=$(awk -v c="$today_cost" -v h="$hours_elapsed" \
                    'BEGIN { printf "%.2f", c/h }')
                debug_log "quota_progress daily fallback burn: \$${cost_per_hour}/hr (today=\$${today_cost}, ${hours_elapsed}h elapsed)" "INFO"
            fi
        fi
    fi

    # Override with realtime 5h burn rate if available and non-zero
    if is_module_loaded "cost" && declare -f get_cached_native_burn_rate &>/dev/null; then
        local rt_burn_data rt_cost_per_hour
        rt_burn_data=$(get_cached_native_burn_rate 2>/dev/null)
        rt_cost_per_hour=$(echo "$rt_burn_data" | cut -d: -f2)
        if [[ -n "$rt_cost_per_hour" ]] && awk -v c="$rt_cost_per_hour" 'BEGIN{exit !(c+0 > 0)}' 2>/dev/null; then
            cost_per_hour="$rt_cost_per_hour"
            debug_log "quota_progress using realtime burn rate: \$${cost_per_hour}/hr" "INFO"
        fi
    fi

    # Calculate expiry if we have a valid burn rate
    if [[ -n "$cost_per_hour" ]] && awk -v c="$cost_per_hour" 'BEGIN{exit !(c+0 > 0)}' 2>/dev/null; then
        local remaining_dollars
        remaining_dollars=$(awk -v limit="$COMPONENT_QUOTA_LIMIT" -v used="$COMPONENT_QUOTA_USED" \
            'BEGIN { r = limit - used; if (r < 0) r = 0; printf "%.2f", r }')

        if awk -v r="$remaining_dollars" 'BEGIN{exit !(r+0 > 0)}' 2>/dev/null; then
            local hours_remaining expiry_epoch expiry_time
            hours_remaining=$(awk -v r="$remaining_dollars" -v rate="$cost_per_hour" \
                'BEGIN { printf "%.1f", r / rate }')
            expiry_epoch=$(awk -v h="$hours_remaining" -v now="$(date +%s)" \
                'BEGIN { printf "%d", now + (h * 3600) }')

            if [[ "$(uname -s)" == "Darwin" ]]; then
                expiry_time=$(date -r "$expiry_epoch" "+%H:%M" 2>/dev/null)
            else
                expiry_time=$(date -d "@$expiry_epoch" "+%H:%M" 2>/dev/null)
            fi

            COMPONENT_QUOTA_EXPIRY="→ 남은 시간: ~${hours_remaining}h / 예상 만료: ${expiry_time}"
            debug_log "quota_progress expiry: $COMPONENT_QUOTA_EXPIRY (burn=\$${cost_per_hour}/hr)" "INFO"
        fi
    fi

    return 0
}

# ============================================================================
# COMPONENT RENDERING
# ============================================================================

# Render quota progress bar display
render_quota_progress() {
    local theme_enabled="${1:-true}"

    # Skip if disabled
    local enabled="${CONFIG_FEATURES_SHOW_QUOTA_PROGRESS:-true}"
    if [[ "$enabled" != "true" ]]; then
        return 1
    fi

    # Skip if no quota limit configured
    if [[ -z "$COMPONENT_QUOTA_LIMIT" || "$COMPONENT_QUOTA_LIMIT" == "0" ]]; then
        return 1
    fi

    local percentage="${COMPONENT_QUOTA_PERCENTAGE:-0}"
    local used="${COMPONENT_QUOTA_USED:-0.00}"
    local limit="${COMPONENT_QUOTA_LIMIT:-200.00}"

    # Config with ENV override support
    local label="${ENV_CONFIG_QUOTA_LABEL:-${CONFIG_QUOTA_LABEL:-Quota:}}"
    local bar_width="${ENV_CONFIG_QUOTA_BAR_WIDTH:-${CONFIG_QUOTA_BAR_WIDTH:-20}}"
    local fill_char="${ENV_CONFIG_QUOTA_FILL_CHAR:-${CONFIG_QUOTA_FILL_CHAR:-█}}"
    local empty_char="${ENV_CONFIG_QUOTA_EMPTY_CHAR:-${CONFIG_QUOTA_EMPTY_CHAR:-░}}"
    local warn_threshold="${ENV_CONFIG_QUOTA_WARN_THRESHOLD:-${CONFIG_QUOTA_WARN_THRESHOLD:-50}}"
    local critical_threshold="${ENV_CONFIG_QUOTA_CRITICAL_THRESHOLD:-${CONFIG_QUOTA_CRITICAL_THRESHOLD:-80}}"

    # Determine color based on percentage
    local bar_color="" pct_color="" reset_color=""
    if [[ "$theme_enabled" == "true" ]] && is_module_loaded "themes"; then
        reset_color="${COLOR_RESET:-\033[0m}"
        if [[ "$percentage" -ge "$critical_threshold" ]]; then
            bar_color="${CONFIG_RED:-\033[31m}"
            pct_color="${CONFIG_RED:-\033[31m}"
        elif [[ "$percentage" -ge "$warn_threshold" ]]; then
            bar_color="${CONFIG_YELLOW:-\033[33m}"
            pct_color="${CONFIG_YELLOW:-\033[33m}"
        else
            bar_color="${CONFIG_GREEN:-\033[32m}"
            pct_color="${CONFIG_GREEN:-\033[32m}"
        fi
    fi

    # Build progress bar inline (avoid subshell capture issues)
    local clamped_pct="$percentage"
    [[ "$clamped_pct" -gt 100 ]] && clamped_pct=100
    [[ "$clamped_pct" -lt 0 ]] && clamped_pct=0
    local filled=$(( (clamped_pct * bar_width + 50) / 100 ))
    local empty_count=$((bar_width - filled))
    local bar=""
    local i
    for ((i = 0; i < filled; i++)); do bar+="${fill_char}"; done
    for ((i = 0; i < empty_count; i++)); do bar+="${empty_char}"; done

    # Display percentage (allow >100% for overage)
    local display_pct="$percentage"

    # Format dollar amounts
    local used_fmt limit_fmt
    used_fmt=$(printf "%.2f" "$used" 2>/dev/null || echo "$used")
    limit_fmt=$(printf "%.2f" "$limit" 2>/dev/null || echo "$limit")

    # Overage warning
    local overage_indicator=""
    if [[ "$display_pct" -gt 100 ]]; then
        overage_indicator=" ⚠️ OVER"
    fi

    # Final output: color the bar only, brackets uncolored
    printf '%s [%b%s%b] %b%s%%%b $%s/$%s%s%s\n' \
        "$label" \
        "$bar_color" "$bar" "$reset_color" \
        "$pct_color" "$display_pct" "$reset_color" \
        "$used_fmt" "$limit_fmt" "$overage_indicator" \
        "${COMPONENT_QUOTA_EXPIRY:+ $COMPONENT_QUOTA_EXPIRY}"
}

# ============================================================================
# COMPONENT CONFIGURATION
# ============================================================================

# Get quota progress configuration
get_quota_progress_config() {
    local key="${1:-component_name}"
    local default="${2:-}"

    case "$key" in
        "component_name"|"name")
            echo "quota_progress"
            ;;
        "enabled")
            echo "${CONFIG_FEATURES_SHOW_QUOTA_PROGRESS:-${default:-true}}"
            ;;
        "monthly_limit")
            echo "${CONFIG_QUOTA_MONTHLY_LIMIT:-${default:-200.00}}"
            ;;
        "bar_width")
            echo "${CONFIG_QUOTA_BAR_WIDTH:-${default:-20}}"
            ;;
        "warn_threshold")
            echo "${CONFIG_QUOTA_WARN_THRESHOLD:-${default:-50}}"
            ;;
        "critical_threshold")
            echo "${CONFIG_QUOTA_CRITICAL_THRESHOLD:-${default:-80}}"
            ;;
        "description")
            echo "Enterprise quota usage progress bar"
            ;;
        *)
            echo "$default"
            ;;
    esac
}

# ============================================================================
# COMPONENT INTERFACE COMPLIANCE
# ============================================================================

# Component metadata
QUOTA_PROGRESS_COMPONENT_NAME="quota_progress"
QUOTA_PROGRESS_COMPONENT_DESCRIPTION="Enterprise quota usage progress bar"
QUOTA_PROGRESS_COMPONENT_VERSION="1.0.0"
QUOTA_PROGRESS_COMPONENT_DEPENDENCIES=("cost" "display")

# ============================================================================
# COMPONENT REGISTRATION
# ============================================================================

# Register the quota_progress component
register_component \
    "quota_progress" \
    "Enterprise quota usage progress bar" \
    "cost display" \
    "true"

# Export component functions
export -f render_progress_bar fetch_quota_from_api collect_quota_progress_data render_quota_progress get_quota_progress_config
export COMPONENT_QUOTA_EXPIRY

debug_log "Quota progress component loaded successfully" "INFO"
