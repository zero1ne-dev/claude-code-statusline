#!/bin/bash

# ============================================================================
# Claude Code Statusline - Extra Usage Quota Progress Bar Component
# ============================================================================
#
# Displays extra usage quota as a visual progress bar for plans that support it
# (Enterprise/Team with extra usage enabled). Auto-hides when not applicable
# (e.g. Max/Pro plans without extra usage). Limit is always read from the API
# — never hardcoded — so per-member Enterprise limits are respected.
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
# API returns cents: monthly_limit (plan/member-specific), used_credits
# Also returns pre-calculated utilization percentage
# Caches full JSON blob with 1-minute TTL
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
        # Only cache valid responses (not errors)
        local has_error
        has_error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
        if [[ -z "$has_error" ]]; then
            echo "$response" > "$cache_file" 2>/dev/null
            debug_log "quota_progress: fetched fresh usage data from API" "INFO"
            echo "$response"
            return 0
        else
            debug_log "quota_progress: API returned error, not caching" "INFO"
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
    COMPONENT_QUOTA_MODE=""  # "extra_usage" or "windows"

    # Window data (for non-extra-usage plans: Max, Pro, etc.)
    COMPONENT_QUOTA_WINDOWS=()

    # Fetch full API response (includes extra_usage + all rate windows)
    local api_response
    api_response=$(fetch_quota_from_api 2>/dev/null)

    if [[ -n "$api_response" ]]; then
        # Check if extra_usage is available and enabled
        local is_enabled limit_cents used_cents utilization
        is_enabled=$(echo "$api_response" | jq -r '.extra_usage.is_enabled // empty' 2>/dev/null)
        limit_cents=$(echo "$api_response" | jq -r '.extra_usage.monthly_limit // empty' 2>/dev/null)
        used_cents=$(echo "$api_response" | jq -r '.extra_usage.used_credits // empty' 2>/dev/null)
        utilization=$(echo "$api_response" | jq -r '.extra_usage.utilization // empty' 2>/dev/null)

        if [[ "$is_enabled" == "true" && -n "$limit_cents" && "$limit_cents" != "null" && "$limit_cents" != "0" ]]; then
            # Enterprise/Team with extra usage → dollar-based quota bar
            COMPONENT_QUOTA_MODE="extra_usage"
            COMPONENT_QUOTA_LIMIT=$(echo "scale=2; $limit_cents / 100" | bc 2>/dev/null || printf "%.2f" "$(echo "$limit_cents * 0.01" | bc 2>/dev/null)")
            COMPONENT_QUOTA_USED=$(echo "scale=2; ${used_cents:-0} / 100" | bc 2>/dev/null || printf "%.2f" "$(echo "${used_cents:-0} * 0.01" | bc 2>/dev/null)")
            if [[ -n "$utilization" && "$utilization" != "null" ]]; then
                COMPONENT_QUOTA_PERCENTAGE=$(printf "%.0f" "$utilization" 2>/dev/null || echo "0")
            fi
            debug_log "quota_progress: extra_usage mode limit=\$$COMPONENT_QUOTA_LIMIT used=\$$COMPONENT_QUOTA_USED pct=$COMPONENT_QUOTA_PERCENTAGE%" "INFO"
        else
            # Max/Pro plan → show all rate windows with progress bars
            COMPONENT_QUOTA_MODE="windows"
            local window_keys
            window_keys=$(echo "$api_response" | jq -r 'keys[]' 2>/dev/null)

            for key in $window_keys; do
                # Skip non-window fields
                [[ "$key" == "extra_usage" || "$key" == "iguana_necktie" ]] && continue

                local win_util win_reset
                win_util=$(echo "$api_response" | jq -r ".${key}.utilization // empty" 2>/dev/null)
                win_reset=$(echo "$api_response" | jq -r ".${key}.resets_at // empty" 2>/dev/null)

                # Skip null/empty windows
                [[ -z "$win_util" || "$win_util" == "null" ]] && continue

                # Format window name for display
                local display_name
                case "$key" in
                    five_hour)          display_name="5H" ;;
                    seven_day)          display_name="7DAY" ;;
                    seven_day_sonnet)   display_name="7D Sonnet" ;;
                    seven_day_opus)     display_name="7D Opus" ;;
                    seven_day_oauth_apps) display_name="7D OAuth" ;;
                    seven_day_cowork)   display_name="7D Cowork" ;;
                    *)                  display_name="$key" ;;
                esac

                local pct_int
                pct_int=$(printf "%.0f" "$win_util" 2>/dev/null || echo "0")

                # Format reset time as remaining countdown
                local reset_display=""
                if [[ -n "$win_reset" && "$win_reset" != "null" ]]; then
                    local reset_epoch now_epoch remaining_secs
                    now_epoch=$(date +%s)

                    # Parse ISO 8601 timestamp
                    if [[ "$win_reset" =~ ^[0-9]+$ ]]; then
                        reset_epoch="$win_reset"
                    elif [[ "$(uname -s)" == "Darwin" ]]; then
                        # macOS: strip fractional seconds and timezone colon for date -j
                        local clean_ts
                        clean_ts=$(echo "$win_reset" | sed 's/\.[0-9]*//; s/\+00:00$/+0000/; s/Z$/+0000/')
                        reset_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$clean_ts" "+%s" 2>/dev/null || echo "")
                    else
                        reset_epoch=$(date -d "$win_reset" "+%s" 2>/dev/null || echo "")
                    fi

                    if [[ -n "$reset_epoch" && "$reset_epoch" -gt "$now_epoch" ]]; then
                        remaining_secs=$((reset_epoch - now_epoch))
                        local days=$((remaining_secs / 86400))
                        local hours=$(( (remaining_secs % 86400) / 3600 ))
                        local mins=$(( (remaining_secs % 3600) / 60 ))

                        if [[ "$days" -gt 0 ]]; then
                            reset_display="${days}d ${hours}h"
                        elif [[ "$hours" -gt 0 ]]; then
                            reset_display="${hours}h ${mins}m"
                        else
                            reset_display="${mins}m"
                        fi
                    fi
                fi

                # Store as "name|percentage|reset_display"
                COMPONENT_QUOTA_WINDOWS+=("${display_name}|${pct_int}|${reset_display}")
                debug_log "quota_progress window: ${display_name} ${pct_int}% reset=${reset_display}" "INFO"
            done

            debug_log "quota_progress: windows mode, ${#COMPONENT_QUOTA_WINDOWS[@]} windows found" "INFO"
        fi
    fi

    # Fallback: use native rate_limits from Claude Code JSON input (always available)
    if [[ "$COMPONENT_QUOTA_MODE" != "extra_usage" && "$COMPONENT_QUOTA_MODE" != "windows" && -n "${STATUSLINE_INPUT_JSON:-}" ]]; then
        local rl_five rl_seven rl_five_reset rl_seven_reset
        rl_five=$(echo "$STATUSLINE_INPUT_JSON" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
        rl_seven=$(echo "$STATUSLINE_INPUT_JSON" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)

        if [[ -n "$rl_five" || -n "$rl_seven" ]]; then
            COMPONENT_QUOTA_MODE="windows"

            if [[ -n "$rl_five" ]]; then
                rl_five_reset=$(echo "$STATUSLINE_INPUT_JSON" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
                local five_pct five_remain=""
                five_pct=$(printf "%.0f" "$rl_five" 2>/dev/null || echo "0")

                if [[ -n "$rl_five_reset" && "$rl_five_reset" != "null" ]]; then
                    local now_ep=$( date +%s )
                    local reset_ep="$rl_five_reset"
                    # Handle ISO 8601 if needed
                    if [[ ! "$reset_ep" =~ ^[0-9]+$ ]]; then
                        if [[ "$(uname -s)" == "Darwin" ]]; then
                            local ct; ct=$(echo "$reset_ep" | sed 's/\.[0-9]*//; s/\+00:00$/+0000/; s/Z$/+0000/')
                            reset_ep=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ct" "+%s" 2>/dev/null || echo "")
                        else
                            reset_ep=$(date -d "$reset_ep" "+%s" 2>/dev/null || echo "")
                        fi
                    fi
                    if [[ -n "$reset_ep" && "$reset_ep" -gt "$now_ep" ]]; then
                        local rs=$((reset_ep - now_ep))
                        local rh=$(( rs / 3600 )) rm=$(( (rs % 3600) / 60 ))
                        five_remain="${rh}h ${rm}m"
                    fi
                fi

                COMPONENT_QUOTA_WINDOWS+=("5H|${five_pct}|${five_remain}")
            fi

            if [[ -n "$rl_seven" ]]; then
                rl_seven_reset=$(echo "$STATUSLINE_INPUT_JSON" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)
                local seven_pct seven_remain=""
                seven_pct=$(printf "%.0f" "$rl_seven" 2>/dev/null || echo "0")

                if [[ -n "$rl_seven_reset" && "$rl_seven_reset" != "null" ]]; then
                    local now_ep=$( date +%s )
                    local reset_ep="$rl_seven_reset"
                    if [[ ! "$reset_ep" =~ ^[0-9]+$ ]]; then
                        if [[ "$(uname -s)" == "Darwin" ]]; then
                            local ct; ct=$(echo "$reset_ep" | sed 's/\.[0-9]*//; s/\+00:00$/+0000/; s/Z$/+0000/')
                            reset_ep=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ct" "+%s" 2>/dev/null || echo "")
                        else
                            reset_ep=$(date -d "$reset_ep" "+%s" 2>/dev/null || echo "")
                        fi
                    fi
                    if [[ -n "$reset_ep" && "$reset_ep" -gt "$now_ep" ]]; then
                        local rs=$((reset_ep - now_ep))
                        local rd=$((rs / 86400)) rh=$(( (rs % 86400) / 3600 )) rm=$(( (rs % 3600) / 60 ))
                        if [[ "$rd" -gt 0 ]]; then
                            seven_remain="${rd}d ${rh}h"
                        else
                            seven_remain="${rh}h ${rm}m"
                        fi
                    fi
                fi

                COMPONENT_QUOTA_WINDOWS+=("7DAY|${seven_pct}|${seven_remain}")
            fi

            debug_log "quota_progress: native rate_limits fallback, ${#COMPONENT_QUOTA_WINDOWS[@]} windows" "INFO"
        fi
    fi

    # Config fallback for extra_usage mode only (when user explicitly sets a limit)
    if [[ "$COMPONENT_QUOTA_MODE" != "extra_usage" && "$COMPONENT_QUOTA_MODE" != "windows" ]]; then
        local explicit_limit="${ENV_CONFIG_QUOTA_MONTHLY_LIMIT:-${CONFIG_QUOTA_MONTHLY_LIMIT:-}}"
        if [[ -n "$explicit_limit" && "$explicit_limit" != "0" && "$explicit_limit" != "0.00" ]]; then
            COMPONENT_QUOTA_MODE="extra_usage"
            COMPONENT_QUOTA_LIMIT="$explicit_limit"

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

            local used_c limit_c
            used_c=$(printf "%.0f" "$(echo "$COMPONENT_QUOTA_USED * 100" | bc 2>/dev/null || echo "0")")
            limit_c=$(printf "%.0f" "$(echo "$COMPONENT_QUOTA_LIMIT * 100" | bc 2>/dev/null || echo "1")")
            if [[ "$limit_c" -gt 0 ]]; then
                COMPONENT_QUOTA_PERCENTAGE=$(( (used_c * 100 + limit_c / 2) / limit_c ))
            fi
            debug_log "quota_progress config fallback: limit=\$$COMPONENT_QUOTA_LIMIT" "INFO"
        else
            debug_log "quota_progress: no data available — hiding component" "INFO"
        fi
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

    # Route to the appropriate renderer based on mode
    if [[ "$COMPONENT_QUOTA_MODE" == "windows" ]]; then
        _render_quota_windows "$theme_enabled"
        return $?
    elif [[ "$COMPONENT_QUOTA_MODE" == "extra_usage" ]]; then
        _render_quota_extra_usage "$theme_enabled"
        return $?
    fi

    # No data at all
    return 1
}

# Render rate-window progress bars (Max/Pro plans)
# Format: Usage: [████░░░░░░] 5H 4% (3h 21m) │ [██░░░░░░░░] 7DAY 10% (2d 15h) │ 7D Sonnet 0%
_render_quota_windows() {
    local theme_enabled="${1:-true}"

    if [[ ${#COMPONENT_QUOTA_WINDOWS[@]} -eq 0 ]]; then
        return 1
    fi

    local label="${ENV_CONFIG_QUOTA_LABEL:-${CONFIG_QUOTA_LABEL:-Usage:}}"
    local bar_width="${ENV_CONFIG_QUOTA_WINDOW_BAR_WIDTH:-${CONFIG_QUOTA_WINDOW_BAR_WIDTH:-8}}"
    local fill_char="${ENV_CONFIG_QUOTA_FILL_CHAR:-${CONFIG_QUOTA_FILL_CHAR:-█}}"
    local empty_char="${ENV_CONFIG_QUOTA_EMPTY_CHAR:-${CONFIG_QUOTA_EMPTY_CHAR:-░}}"
    local warn_threshold="${ENV_CONFIG_QUOTA_WARN_THRESHOLD:-${CONFIG_QUOTA_WARN_THRESHOLD:-50}}"
    local critical_threshold="${ENV_CONFIG_QUOTA_CRITICAL_THRESHOLD:-${CONFIG_QUOTA_CRITICAL_THRESHOLD:-80}}"

    local output="$label"
    local first=true

    for entry in "${COMPONENT_QUOTA_WINDOWS[@]}"; do
        local name pct reset_str
        name=$(echo "$entry" | cut -d'|' -f1)
        pct=$(echo "$entry" | cut -d'|' -f2)
        reset_str=$(echo "$entry" | cut -d'|' -f3)

        # Color based on percentage
        local bar_color="" pct_color="" reset_color=""
        if [[ "$theme_enabled" == "true" ]] && is_module_loaded "themes"; then
            reset_color="${COLOR_RESET:-\033[0m}"
            if [[ "$pct" -ge "$critical_threshold" ]]; then
                bar_color="${CONFIG_RED:-\033[31m}"
                pct_color="${CONFIG_RED:-\033[31m}"
            elif [[ "$pct" -ge "$warn_threshold" ]]; then
                bar_color="${CONFIG_YELLOW:-\033[33m}"
                pct_color="${CONFIG_YELLOW:-\033[33m}"
            else
                bar_color="${CONFIG_GREEN:-\033[32m}"
                pct_color="${CONFIG_GREEN:-\033[32m}"
            fi
        fi

        # Build mini progress bar
        local clamped=$pct
        [[ "$clamped" -gt 100 ]] && clamped=100
        [[ "$clamped" -lt 0 ]] && clamped=0
        local filled=$(( (clamped * bar_width + 50) / 100 ))
        local empty_count=$((bar_width - filled))
        local bar=""
        local i
        for ((i = 0; i < filled; i++)); do bar+="${fill_char}"; done
        for ((i = 0; i < empty_count; i++)); do bar+="${empty_char}"; done

        # Separator
        if [[ "$first" == "true" ]]; then
            first=false
        else
            output+=" │"
        fi

        # Format: [████░░░░░░] 5H 4% (3h 21m)
        local reset_part=""
        if [[ -n "$reset_str" ]]; then
            reset_part=" (${reset_str})"
        fi
        output+=$(printf ' [%b%s%b] %b%s %s%%%b%s' \
            "$bar_color" "$bar" "$reset_color" \
            "$pct_color" "$name" "$pct" "$reset_color" \
            "$reset_part")
    done

    echo -e "$output"
}

# Render extra_usage dollar-based quota bar (Enterprise/Team)
_render_quota_extra_usage() {
    local theme_enabled="${1:-true}"

    # Skip if no quota limit
    if [[ -z "$COMPONENT_QUOTA_LIMIT" || "$COMPONENT_QUOTA_LIMIT" == "0" || "$COMPONENT_QUOTA_LIMIT" == "0.00" ]]; then
        return 1
    fi

    local percentage="${COMPONENT_QUOTA_PERCENTAGE:-0}"
    local used="${COMPONENT_QUOTA_USED:-0.00}"
    local limit="${COMPONENT_QUOTA_LIMIT:-0.00}"

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

    # Build progress bar
    local clamped_pct="$percentage"
    [[ "$clamped_pct" -gt 100 ]] && clamped_pct=100
    [[ "$clamped_pct" -lt 0 ]] && clamped_pct=0
    local filled=$(( (clamped_pct * bar_width + 50) / 100 ))
    local empty_count=$((bar_width - filled))
    local bar=""
    local i
    for ((i = 0; i < filled; i++)); do bar+="${fill_char}"; done
    for ((i = 0; i < empty_count; i++)); do bar+="${empty_char}"; done

    local display_pct="$percentage"
    local used_fmt limit_fmt
    used_fmt=$(printf "%.2f" "$used" 2>/dev/null || echo "$used")
    limit_fmt=$(printf "%.2f" "$limit" 2>/dev/null || echo "$limit")

    local overage_indicator=""
    if [[ "$display_pct" -gt 100 ]]; then
        overage_indicator=" ⚠️ OVER"
    fi

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
            echo "${CONFIG_QUOTA_MONTHLY_LIMIT:-${default:-}}"
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
            echo "Extra usage quota progress bar (auto-hides when not applicable)"
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
QUOTA_PROGRESS_COMPONENT_DESCRIPTION="Extra usage quota progress bar (Enterprise/Team with extra usage enabled)"
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
