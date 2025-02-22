#!/bin/sh

. /usr/share/libubox/jshn.sh

IP4="ip -4"
IP6="ip -6"
IPS="ipset"
IPT4="iptables -t mangle -w"
IPT6="ip6tables -t mangle -w"
IPT4R="iptables-restore -T mangle -w -n"
IPT6R="ip6tables-restore -T mangle -w -n"
CONNTRACK_FILE="/proc/net/nf_conntrack"
IPv4_REGEX="((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
IPv6_REGEX="([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,7}:|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|"
IPv6_REGEX="${IPv6_REGEX}[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|"
IPv6_REGEX="${IPv6_REGEX}:((:[0-9a-fA-F]{1,4}){1,7}|:)|"
IPv6_REGEX="${IPv6_REGEX}fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|"
IPv6_REGEX="${IPv6_REGEX}::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|"
IPv6_REGEX="${IPv6_REGEX}([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])"

MWAN3_INTERFACE_MAX=""
DEFAULT_LOWEST_METRIC=256
MMX_MASK=""
MMX_DEFAULT=""
MMX_BLACKHOLE=""
MM_BLACKHOLE=""

MMX_UNREACHABLE=""
MM_UNREACHABLE=""

command -v ip6tables > /dev/null
NO_IPV6=$?
NEED_IPV4=0
NEED_IPV6=0

mwan3_init_post()
{
	local enabled family
	check_family()
	{
		config_get enabled "$1" enabled 0
		config_get family "$1" family "any"

		[ "$enabled" = "0" ] && return
		if [ "$family" = "any" ]; then
			NEED_IPV4=1
			NEED_IPV6=1
		elif [ "$family" = "ipv4" ]; then
			NEED_IPV4=1
		elif [ "$family" = "ipv6" ]; then
			NEED_IPV6=1
		fi
	}
	config_foreach check_family interface
	[ $NO_IPV6 -ne 0 ] && NEED_IPV6=0
}

# help ipv6 masq when network interface ifup/ifdown
mwan3_ipv6_masq_help()
{
	local family enabled

	config_get enabled "$INTERFACE" enabled 0
	config_get family "$INTERFACE" family "any"
	[ "$enabled" = "1" ] || return
	[ "$family" = "ipv6" ] || [ "$family" = "any" ] || return

	ip6tables -t nat -S POSTROUTING 2>/dev/null | grep "masq-help-${INTERFACE}-dev" | sed 's/^-A //' | while read line; do
		`echo ip6tables -t nat -D $line | sed 's/"//g'`
		$IPS destroy mwan3_${INTERFACE}_ipv6_src_from &>/dev/null
	done

	LOG debug "mwan3_ipv6_masq_help stage1 on INTERFACE=$INTERFACE DEVICE=$DEVICE ACTION=$ACTION"

	[ "$ACTION" = "ifup" ] || return

	$IPS destroy mwan3_${INTERFACE}_ipv6_src_from &>/dev/null
	$IP6 route list table main | grep "\(^default\|^::/0\) from.*dev ${DEVICE} " | sed 's/.* from \([^ ]*\) .*dev \([^ ]*\) .*/\1 \2/' | while read from dev; do
		$IPS list -n mwan3_${INTERFACE}_ipv6_src_from &>/dev/null || $IPS create mwan3_${INTERFACE}_ipv6_src_from hash:net hashsize 128 family inet6
		$IPS add mwan3_${INTERFACE}_ipv6_src_from $from
	done

	if $IPS list -n mwan3_${INTERFACE}_ipv6_src_from &>/dev/null; then
		ip6tables -t nat -A POSTROUTING -m set ! --match-set mwan3_${INTERFACE}_ipv6_src_from src -o ${DEVICE} -m comment --comment "masq-help-${INTERFACE}-dev" -j MASQUERADE
	else
		LOG notice "mwan3_ipv6_masq_help stage2 on INTERFACE=$INTERFACE DEVICE=$DEVICE ACTION=$ACTION no masq set"
	fi

	LOG debug "mwan3_ipv6_masq_help stage2 on INTERFACE=$INTERFACE DEVICE=$DEVICE ACTION=$ACTION"
}

mwan3_ipv6_masq_cleanup()
{
	ip6tables -t nat -S POSTROUTING 2>/dev/null | grep masq-help-.*-dev | sed 's/^-A //' | while read line; do
		`echo ip6tables -t nat -D $line | sed 's/"//g'`
	done
	$IPS list -n | grep "mwan3_.*_ipv6_src_from" | while read line; do
		$IPS destroy $line &>/dev/null
	done
}

mwan3_push_update()
{
	# helper function to build an update string to pass on to
	# IPTR or IPS RESTORE. Modifies the 'update' variable in
	# the local scope.
	update="$update
$*";
}

mwan3_update_dev_to_table()
{
	local _tid
	# shellcheck disable=SC2034
	mwan3_dev_tbl_ipv4=" "
	# shellcheck disable=SC2034
	mwan3_dev_tbl_ipv6=" "

	update_table()
	{
		local family family_list curr_table device enabled
		let _tid++
		config_get family_list "$1" family "any"
		[ "$family_list" = "any" ] && family_list="ipv4 ipv6"
		for family in $family_list; do

		network_get_device device "$1"
		[ -z "$device" ] && continue
		config_get enabled "$1" enabled
		[ "$enabled" -eq 0 ] && continue
		curr_table=$(eval "echo	 \"\$mwan3_dev_tbl_${family}\"")
		export "mwan3_dev_tbl_$family=${curr_table}${device}=$_tid "

		done
	}
	network_flush_cache
	config_foreach update_table interface
}

mwan3_update_iface_to_table()
{
	local _tid
	mwan3_iface_tbl=" "
	update_table()
	{
		let _tid++
		export mwan3_iface_tbl="${mwan3_iface_tbl}${1}=$_tid "
	}
	config_foreach update_table interface
}

mwan3_get_true_iface()
{
	local family V iface _true_iface
	family=$3
	iface="$2"
	_true_iface=$2
	if [ "$family" = "ipv4" ]; then
		V=4
	elif [ "$family" = "ipv6" ]; then
		V=6
	fi
	ubus call "network.interface.${iface}_${V}" status &>/dev/null && _true_iface="${iface}_${V}"
	export "$1=$_true_iface"
}

mwan3_route_line_dev()
{
	# must have mwan3 config already loaded
	# arg 1 is route device
	local _tid route_line route_device route_family entry curr_table
	route_line=$2
	route_family=$3
	route_device=$(echo "$route_line" | sed -ne "s/.*dev \([^ ]*\).*/\1/p")
	unset "$1"
	[ -z "$route_device" ] && return

	curr_table=$(eval "echo	 \"\$mwan3_dev_tbl_${route_family}\"")
	for entry in $curr_table; do
		if [ "${entry%%=*}" = "$route_device" ]; then
			_tid=${entry##*=}
			export "$1=$_tid"
			return
		fi
	done
}

# counts how many bits are set to 1
# n&(n-1) clears the lowest bit set to 1
mwan3_count_one_bits()
{
	local count n
	count=0
	n=$(($1))
	while [ "$n" -gt "0" ]; do
		n=$((n&(n-1)))
		count=$((count+1))
	done
	echo $count
}

# maps the 1st parameter so it only uses the bits allowed by the bitmask (2nd parameter)
# which means spreading the bits of the 1st parameter to only use the bits that are set to 1 in the 2nd parameter
# 0 0 0 0 0 1 0 1 (0x05) 1st parameter
# 1 0 1 0 1 0 1 0 (0xAA) 2nd parameter
#     1   0   1          result
mwan3_id2mask()
{
	local bit_msk bit_val result
	bit_val=0
	result=0
	for bit_msk in $(seq 0 31); do
		if [ $((($2>>bit_msk)&1)) = "1" ]; then
			if [ $((($1>>bit_val)&1)) = "1" ]; then
				result=$((result|(1<<bit_msk)))
			fi
			bit_val=$((bit_val+1))
		fi
	done
	printf "0x%x" $result
}

mwan3_init()
{
	local bitcnt
	local mmdefault

	[ -d $MWAN3_STATUS_DIR ] || mkdir -p $MWAN3_STATUS_DIR/iface_state

	# mwan3's MARKing mask (at least 3 bits should be set)
	if [ -e "${MWAN3_STATUS_DIR}/mmx_mask" ]; then
		MMX_MASK=$(cat "${MWAN3_STATUS_DIR}/mmx_mask")
		MWAN3_INTERFACE_MAX=$(uci_get_state mwan3 globals iface_max)
	else
		config_load mwan3
		config_get MMX_MASK globals mmx_mask '0x3F00'
		echo "$MMX_MASK"| tr 'A-F' 'a-f' > "${MWAN3_STATUS_DIR}/mmx_mask"
		LOG debug "Using firewall mask ${MMX_MASK}"

		bitcnt=$(mwan3_count_one_bits MMX_MASK)
		mmdefault=$(((1<<bitcnt)-1))
		MWAN3_INTERFACE_MAX=$((mmdefault-3))
		uci_toggle_state mwan3 globals iface_max "$MWAN3_INTERFACE_MAX"
		LOG debug "Max interface count is ${MWAN3_INTERFACE_MAX}"
	fi

	# mark mask constants
	bitcnt=$(mwan3_count_one_bits MMX_MASK)
	mmdefault=$(((1<<bitcnt)-1))
	MM_BLACKHOLE=$((mmdefault-2))
	MM_UNREACHABLE=$((mmdefault-1))

	# MMX_DEFAULT should equal MMX_MASK
	MMX_DEFAULT=$(mwan3_id2mask mmdefault MMX_MASK)
	MMX_BLACKHOLE=$(mwan3_id2mask MM_BLACKHOLE MMX_MASK)
	MMX_UNREACHABLE=$(mwan3_id2mask MM_UNREACHABLE MMX_MASK)

	mwan3_init_post
}

mwan3_lock() {
	lock /var/run/mwan3.lock
	#LOG debug "$1 $2 (lock)"
}

mwan3_unlock() {
	#LOG debug "$1 $2 (unlock)"
	lock -u /var/run/mwan3.lock
}

mwan3_get_src_ip()
{
	local family _src_ip INTERFACE true_iface
	INTERFACE=$2
	unset "$1"
	config_get family "$INTERFACE" family "any"
	[ "$family" = "any" ] && family="ipv4"
	if [ "$family" = "ipv4" ]; then
		mwan3_get_true_iface true_iface "$INTERFACE" $family
		network_get_ipaddr _src_ip "$true_iface"
		[ -n "$_src_ip" ] || _src_ip="0.0.0.0"
	fi
	export "$1=$_src_ip"
}

mwan3_get_src_ip6()
{
	local family _src_ip INTERFACE true_iface
	INTERFACE=$2
	unset "$1"
	config_get family $INTERFACE family "any"
	[ "$family" = "any" ] && family="ipv6"
	if [ "$family" = "ipv6" ]; then
		mwan3_get_true_iface true_iface "$INTERFACE" $family
		network_get_ipaddr6 _src_ip "$true_iface"
		[ -n "$_src_ip" ] || _src_ip="::"
	fi
	export "$1=$_src_ip"
}

mwan3_get_iface_id()
{
	local _tmp
	[ -z "$mwan3_iface_tbl" ] && mwan3_update_iface_to_table
	_tmp="${mwan3_iface_tbl##* ${2}=}"
	_tmp=${_tmp%% *}
	export "$1=$_tmp"
}

mwan3_set_local_ipv4()
{
	local error local_network_v4
	$IPS -! create mwan3_local_v4 hash:net
	$IPS create mwan3_local_v4_temp hash:net ||
		LOG notice "failed to create ipset mwan3_local_v4_temp"

	$IP4 route list table local | awk '{print $2}' | while read local_network_v4; do
		$IPS -! add mwan3_local_v4_temp $local_network_v4 2>/dev/null
	done

	$IPS swap mwan3_local_v4_temp mwan3_local_v4 ||
		LOG notice "failed to swap mwan3_local_v4_temp and mwan3_local_v4"
	$IPS destroy mwan3_local_v4_temp 2>/dev/null
	$IPS -! add mwan3_local mwan3_local_v4
}

mwan3_set_local_ipv6()
{
	local error local_network_v6
	$IPS -! create mwan3_local_v6 hash:net family inet6
	$IPS create mwan3_local_v6_temp hash:net family inet6 ||
		LOG notice "failed to create ipset mwan3_local_v6_temp"

	$IP6 route list table local | awk '{print $2}' | grep : | while read local_network_v6; do
		$IPS -! add mwan3_local_v6_temp $local_network_v6 2>/dev/null
	done
	$IP6 route list table local | awk '{print $1}' | grep : | while read local_network_v6; do
		$IPS -! add mwan3_local_v6_temp $local_network_v6 2>/dev/null
	done

	$IPS swap mwan3_local_v6_temp mwan3_local_v6 ||
		LOG notice "failed to swap mwan3_local_v6_temp and mwan3_local_v6"
	$IPS destroy mwan3_local_v6_temp 2>/dev/null
	$IPS -! add mwan3_local mwan3_local_v6
}

mwan3_set_local_ipset()
{
	local error
	local update=""

	mwan3_push_update -! create mwan3_local list:set
	mwan3_push_update flush mwan3_local

	error=$(echo "$update" | $IPS restore 2>&1) || LOG error "set_local_ipset: $error"

	[ $NEED_IPV4 -ne 0 ] && mwan3_set_local_ipv4
	[ $NEED_IPV6 -ne 0 ] && mwan3_set_local_ipv6
}

mwan3_set_connected_ipv4()
{
	local error connected_network_v4
	$IPS -! create mwan3_connected_v4 hash:net
	$IPS create mwan3_connected_v4_temp hash:net ||
		LOG notice "failed to create ipset mwan3_connected_v4_temp"

	$IP4 route list table main | awk '{print $1}' | grep -E "$IPv4_REGEX" | while read connected_network_v4; do
		$IPS -! add mwan3_connected_v4_temp $connected_network_v4 2>/dev/null
	done

	$IPS swap mwan3_connected_v4_temp mwan3_connected_v4 ||
		LOG notice "failed to swap mwan3_connected_v4_temp and mwan3_connected_v4"
	$IPS destroy mwan3_connected_v4_temp 2>/dev/null
	$IPS -! add mwan3_connected mwan3_connected_v4
}

mwan3_set_connected_ipv6()
{
	local error connected_network_v6
	$IPS -! create mwan3_connected_v6 hash:net family inet6
	$IPS create mwan3_connected_v6_temp hash:net family inet6 ||
		LOG notice "failed to create ipset mwan3_connected_v6_temp"

	$IP6 route list table main | awk '{print $1}' | grep -E "$IPv6_REGEX" | while read connected_network_v6; do
		$IPS -! add mwan3_connected_v6_temp $connected_network_v6 2>/dev/null
	done

	$IPS swap mwan3_connected_v6_temp mwan3_connected_v6 ||
		LOG notice "failed to swap mwan3_connected_v6_temp and mwan3_connected_v6"
	$IPS destroy mwan3_connected_v6_temp 2>/dev/null
	$IPS -! add mwan3_connected mwan3_connected_v6
}

mwan3_set_connected_ipset()
{
	local error
	local update=""

	mwan3_push_update -! create mwan3_connected list:set
	mwan3_push_update flush mwan3_connected

	error=$(echo "$update" | $IPS restore 2>&1) || LOG error "set_connected_ipset: $error"

	[ $NEED_IPV4 -ne 0 ] && mwan3_set_connected_ipv4
	[ $NEED_IPV6 -ne 0 ] && mwan3_set_connected_ipv6
}

mwan3_set_general_rules()
{
	local IP

	for IP in "$IP4" "$IP6"; do
		[ "$IP" = "$IP4" ] && [ $NEED_IPV4 -eq 0 ] && continue
		[ "$IP" = "$IP6" ] && [ $NEED_IPV6 -eq 0 ] && continue
		RULE_NO=$((MM_BLACKHOLE+2000))
		if [ -z "$($IP rule list | awk -v var="$RULE_NO:" '$1 == var')" ]; then
			$IP rule add pref $RULE_NO fwmark $MMX_BLACKHOLE/$MMX_MASK blackhole
		fi

		RULE_NO=$((MM_UNREACHABLE+2000))
		if [ -z "$($IP rule list | awk -v var="$RULE_NO:" '$1 == var')" ]; then
			$IP rule add pref $RULE_NO fwmark $MMX_UNREACHABLE/$MMX_MASK unreachable
		fi
	done
}

mwan3_set_general_iptables()
{
	local IPT current update error
	for IPT in "$IPT4" "$IPT6"; do
		[ "$IPT" = "$IPT4" ] && [ $NEED_IPV4 -eq 0 ] && continue
		[ "$IPT" = "$IPT6" ] && [ $NEED_IPV6 -eq 0 ] && continue
		current="$($IPT -S 2>/dev/null)"$'\n'
		update="*mangle"
		if [ -n "${current##*-N mwan3_ifaces_in*}" ]; then
			mwan3_push_update -N mwan3_ifaces_in
		fi

		if [ -n "${current##*-N mwan3_local*}" ]; then
			mwan3_push_update -N mwan3_local
			$IPS -! create mwan3_local list:set
			mwan3_push_update -A mwan3_local \
				-m set --match-set mwan3_local dst \
				-j MARK --set-xmark $MMX_DEFAULT/$MMX_MASK
		fi

		if [ -n "${current##*-N mwan3_connected*}" ]; then
			mwan3_push_update -N mwan3_connected
			$IPS -! create mwan3_connected list:set
			mwan3_push_update -A mwan3_connected \
				-m mark --mark $MMX_BLACKHOLE/$MMX_MASK \
				-m set --match-set mwan3_connected dst \
				-j MARK --set-xmark $MMX_DEFAULT/$MMX_MASK
			mwan3_push_update -A mwan3_connected \
				-m mark --mark $MMX_UNREACHABLE/$MMX_MASK \
				-m set --match-set mwan3_connected dst \
				-j MARK --set-xmark $MMX_DEFAULT/$MMX_MASK
			mwan3_push_update -A mwan3_connected \
				-m mark --mark 0x0/$MMX_MASK \
				-m set --match-set mwan3_connected dst \
				-j MARK --set-xmark $MMX_DEFAULT/$MMX_MASK
		fi

		if [ -n "${current##*-N mwan3_rules*}" ]; then
			mwan3_push_update -N mwan3_rules
		fi

		if [ -n "${current##*-N mwan3_hook*}" ]; then
			mwan3_push_update -N mwan3_hook
			# do not mangle ipv6 ra service
			if [ "$IPT" = "$IPT6" ]; then
				mwan3_push_update -A mwan3_hook \
						  -p ipv6-icmp \
						  -m icmp6 --icmpv6-type 133 \
						  -j RETURN
				mwan3_push_update -A mwan3_hook \
						  -p ipv6-icmp \
						  -m icmp6 --icmpv6-type 134 \
						  -j RETURN
				mwan3_push_update -A mwan3_hook \
						  -p ipv6-icmp \
						  -m icmp6 --icmpv6-type 135 \
						  -j RETURN
				mwan3_push_update -A mwan3_hook \
						  -p ipv6-icmp \
						  -m icmp6 --icmpv6-type 136 \
						  -j RETURN
				mwan3_push_update -A mwan3_hook \
						  -p ipv6-icmp \
						  -m icmp6 --icmpv6-type 137 \
						  -j RETURN
			fi
			mwan3_push_update -A mwan3_hook \
					  -m mark --mark 0x0/$MMX_MASK \
					  -j CONNMARK --restore-mark --nfmask "$MMX_MASK" --ctmask "$MMX_MASK"
			mwan3_push_update -A mwan3_hook \
					  -m mark --mark 0x0/$MMX_MASK \
					  -j mwan3_ifaces_in
			mwan3_push_update -A mwan3_hook \
					  -m mark --mark 0x0/$MMX_MASK \
					  -j mwan3_local
			mwan3_push_update -A mwan3_hook \
					  -m mark --mark 0x0/$MMX_MASK \
					  -j mwan3_rules
			mwan3_push_update -A mwan3_hook \
					  -j mwan3_connected
			mwan3_push_update -A mwan3_hook \
					  -j CONNMARK --save-mark --nfmask "$MMX_MASK" --ctmask "$MMX_MASK"
		fi

		if [ -n "${current##*-A PREROUTING -j mwan3_hook*}" ]; then
			mwan3_push_update -A PREROUTING -j mwan3_hook
		fi
		if [ -n "${current##*-A OUTPUT -j mwan3_hook*}" ]; then
			mwan3_push_update -A OUTPUT -j mwan3_hook
		fi
		mwan3_push_update COMMIT
		mwan3_push_update ""
		if [ "$IPT" = "$IPT4" ]; then
			error=$(echo "$update" | $IPT4R 2>&1) || LOG error "set_general_iptables: $error"
		else
			error=$(echo "$update" | $IPT6R 2>&1) || LOG error "set_general_iptables: $error"
		fi
	done
}

mwan3_create_iface_iptables()
{
	local id family IPT IPTR current update error

	config_get family "$1" family "any"
	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0
	[ "$family" = "any" ] && family="$3"
	[ "$family" = "$3" ] || return 0

	if [ "$family" = "ipv4" ] && [ "$NEED_IPV4" -ne 0 ]; then
		IPT="$IPT4"
		IPTR="$IPT4R"
	elif [ "$family" = "ipv6" ] && [ $NEED_IPV6 -ne 0 ]; then
		IPT="$IPT6"
		IPTR="$IPT6R"
	else
		return 0
	fi

	current="$($IPT -S 2>/dev/null)"$'\n'
	update="*mangle"
	if [ -n "${current##*-N mwan3_ifaces_in*}" ]; then
		mwan3_push_update -N mwan3_ifaces_in
	fi

	if [ -n "${current##*-N mwan3_iface_in_$1$'\n'*}" ]; then
		mwan3_push_update -N "mwan3_iface_in_$1"
	else
		mwan3_push_update -F "mwan3_iface_in_$1"
	fi

	mwan3_push_update -A "mwan3_iface_in_$1" \
			  -i "$2" \
			  -m mark --mark "0x0/$MMX_MASK" \
			  -m comment --comment "$1" \
			  -j MARK --set-xmark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK"

	if [ -n "${current##*-A mwan3_ifaces_in -m mark --mark 0x0/$MMX_MASK -j mwan3_iface_in_${1}$'\n'*}" ]; then
		mwan3_push_update -A mwan3_ifaces_in \
				  -m mark --mark 0x0/$MMX_MASK \
				  -j "mwan3_iface_in_$1"
		LOG debug "create_iface_iptables: mwan3_iface_in_$1 not in iptables, adding"
	else
		LOG debug "create_iface_iptables: mwan3_iface_in_$1 already in iptables, skip"
	fi

	mwan3_push_update COMMIT
	mwan3_push_update ""
	error=$(echo "$update" | $IPTR 2>&1) || LOG error "create_iface_iptables: $error"
}

mwan3_delete_iface_iptables()
{
	local IPT family
	config_get family "$1" family "any"
	[ "$family" = "any" ] && family="$2"
	[ "$family" = "$2" ] || return

	if [ "$family" = "ipv4" ] && [ $NEED_IPV4 -ne 0 ]; then
		IPT="$IPT4"
	elif [ "$family" = "ipv6" ] && [ $NEED_IPV6 -ne 0 ]; then
		IPT="$IPT6"
	else
		return
	fi

	$IPT -D mwan3_ifaces_in \
	     -m mark --mark 0x0/$MMX_MASK \
	     -j "mwan3_iface_in_$1" &> /dev/null
	$IPT -F "mwan3_iface_in_$1" &> /dev/null
	$IPT -X "mwan3_iface_in_$1" &> /dev/null
}

mwan3_create_iface_route()
{
	local id via metric V V_ IP family
	local iface device cmd true_iface

	iface=$1
	device=$2
	config_get family "$iface" family "any"
	mwan3_get_iface_id id "$iface"

	[ -n "$id" ] || return 0
	[ "$family" = "any" ] && family="$3"
	[ "$family" = "$3" ] || return 0

	mwan3_get_true_iface true_iface $iface $family
	if [ "$family" = "ipv4" ]; then
		V_=""
		IP="$IP4"
	elif [ "$family" = "ipv6" ]; then
		V_=6
		IP="$IP6"
	else
		return 0
	fi

	network_get_gateway${V_} via "$true_iface"

	{ [ -z "$via" ] || [ "$via" = "0.0.0.0" ] || [ "$via" = "::" ] ; } && unset via

	network_get_metric metric "$true_iface"

	$IP route flush table "$id"
	cmd="$IP route add table $id default \
	     ${via:+via} $via \
	     ${metric:+metric} $metric \
	     dev $2"
	$cmd || LOG warn "ip cmd failed $cmd"
}

mwan3_add_non_default_iface_route()
{
	local tid route_line family IP id
	config_get family "$1" family "any"
	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0
	[ "$family" = "any" ] && family="$3"
	[ "$family" = "$3" ] || return

	if [ "$family" = "ipv4" ]; then
		IP="$IP4"
	elif [ "$family" = "ipv6" ]; then
		IP="$IP6"
	else
		return
	fi

	mwan3_update_dev_to_table
	$IP route list table main | grep -v "^default\|linkdown\|^::/0\|^fe80::/64\|^unreachable" | while read -r route_line; do
		mwan3_route_line_dev "tid" "$route_line" "$family"
		[ -n "${route_line##* expires *}" ] || route_line="${route_line%expires *}${route_line#* expires * }"
		[ "$tid" != "$id" ] && [ -z "${route_line##* scope link*}" ] && \
		[ -n "${route_line##* metric *}" ] && \
		$IP route add table $id $route_line metric ${tid:-256} && {
			LOG debug "adjusting route $device: $IP route add table $id $route_line metric ${tid:-256}"
			continue
		}
		[ "$tid" == "$id" ] && [ -z "${route_line##* scope link*}" ] && \
		[ -z "${route_line##* metric *}" ] && \
		$IP route add table $id ${route_line%% metric *} && {
			LOG debug "adjusting route $device: $IP route add table $id ${route_line%% metric *}"
			continue
		}
		$IP route add table $id $route_line ||
			LOG warn "failed to add $route_line to table $id"

	done
}

mwan3_add_all_nondefault_routes()
{
	local tid IP route_line ipv family active_tbls tid id

	add_active_tbls()
	{
		let tid++
		config_get family "$1" family "any"
		[ "$family" != "$ipv" ] && [ "$family" != "any" ] && return
		$IP route list table $tid 2>/dev/null | grep -q "^default\|^::/0" && {
			active_tbls="$active_tbls${tid} "
		}
	}

	add_route()
	{
		let id++
		[ -n "${active_tbls##* $id *}" ] && return
		[ -n "${route_line##* expires *}" ] || route_line="${route_line%expires *}${route_line#* expires * }"
		[ "$tid" != "$id" ] && [ -z "${route_line##* scope link*}" ] && \
		[ -n "${route_line##* metric *}" ] && \
		$IP route add table $id $route_line metric ${tid:-256} && {
			LOG debug "adjusting route $device: $IP route add table $id $route_line metric ${tid:-256}"
			return
		}
		[ "$tid" == "$id" ] && [ -z "${route_line##* scope link*}" ] && \
		[ -z "${route_line##* metric *}" ] && \
		$IP route add table $id ${route_line%% metric *} && {
			LOG debug "adjusting route $device: $IP route add table $id ${route_line%% metric *}"
			return
		}
		$IP route add table $id $route_line ||
			LOG warn "failed to add $route_line to table $id"
	}

	mwan3_update_dev_to_table
	for ipv in ipv4 ipv6; do
		if [ "$ipv" = "ipv4" ] && [ $NEED_IPV4 -ne 0 ]; then
			IP="$IP4"
		elif [ "$ipv" = "ipv6" ] && [ $NEED_IPV6 -ne 0 ]; then
			IP="$IP6"
		else
			continue
		fi
		active_tbls=" "
		tid=0 config_foreach add_active_tbls interface
		$IP route list table main | grep -v "^default\|linkdown\|^::/0\|^fe80::/64\|^unreachable" | while read -r route_line; do
			mwan3_route_line_dev "tid" "$route_line" "$ipv"
			id=0 config_foreach add_route interface
		done
	done
}
mwan3_delete_iface_route()
{
	local id family

	config_get family "$1" family "any"
	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0
	[ "$family" = "any" ] && family="$2"
	[ "$family" = "$2" ] || return

	if [ "$family" = "ipv4" ] && [ $NEED_IPV4 -ne 0 ]; then
		$IP4 route flush table "$id"
	elif [ "$family" = "ipv6" ] && [ $NEED_IPV6 -ne 0 ]; then
		$IP6 route flush table "$id"
	else
		return
	fi
}

mwan3_create_iface_rules()
{
	local id family IP

	config_get family "$1" family "any"
	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0
	[ "$family" = "any" ] && family="$3"
	[ "$family" = "$3" ] || return 0

	if [ "$family" = "ipv4" ] && [ $NEED_IPV4 -ne 0 ]; then
		IP="$IP4"
	elif [ "$family" = "ipv6" ] && [ $NEED_IPV6 -ne 0 ]; then
		IP="$IP6"
	else
		return 0
	fi

	while [ -n "$($IP rule list | awk '$1 == "'$((id+1000)):'"')" ]; do
		$IP rule del pref $((id+1000))
	done

	while [ -n "$($IP rule list | awk '$1 == "'$((id+2000)):'"')" ]; do
		$IP rule del pref $((id+2000))
	done

	$IP rule add pref $((id+1000)) iif "$2" lookup "$id"
	$IP rule add pref $((id+2000)) fwmark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK" lookup "$id"
}

mwan3_delete_iface_rules()
{
	local id family IP

	config_get family "$1" family "any"
	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0
	[ "$family" = "any" ] && family="$2"
	[ "$family" = "$2" ] || return 0

	if [ "$family" = "ipv4" ] && [ $NEED_IPV4 -ne 0 ]; then
		IP="$IP4"
	elif [ "$family" = "ipv6" ] && [ $NEED_IPV6 -ne 0 ]; then
		IP="$IP6"
	else
		return 0
	fi

	while [ -n "$($IP rule list | awk '$1 == "'$((id+1000)):'"')" ]; do
		$IP rule del pref $((id+1000))
	done

	while [ -n "$($IP rule list | awk '$1 == "'$((id+2000)):'"')" ]; do
		$IP rule del pref $((id+2000))
	done
}

mwan3_delete_iface_ipset_entries()
{
	local id setname entry V

	mwan3_get_iface_id id "$1"

	[ -n "$id" ] || return 0
	V="v4"
	[ "$2" = "ipv6" ] && V="v6"

	for setname in $(ipset -n list | grep ^mwan3_sticky_${V}_); do
		for entry in $(ipset list "$setname" | grep "$(mwan3_id2mask id MMX_MASK | awk '{ printf "0x%08x", $1; }')" | cut -d ' ' -f 1); do
			$IPS del "$setname" $entry
		done
	done
}

mwan3_rtmon()
{
	local family
	for family in "ipv4" "ipv6"; do
		pid="$(pgrep -f "mwan3rtmon $family")"
		[ "$family" = "ipv4" ] && [ $NEED_IPV4 -eq 0 ] && continue
		[ "$family" = "ipv6" ] && [ $NEED_IPV6 -eq 0 ] && continue
		if [ "${pid}" = "" ]; then
			/usr/sbin/mwan3rtmon $family &
		fi
	done
}

mwan3_track()
{
	local track_ips pids
	local track_ips_v4 track_ips_v6

	mwan3_list_track_ips()
	{
		if echo $1 | grep -q ":"; then
			track_ips_v6="$track_ips_v6 $1"
		elif echo $1 | grep -qE "$IPv4_REGEX"; then
			track_ips_v4="$track_ips_v4 $1"
		else
			track_ips_v6="$track_ips_v6 $1"
			track_ips_v4="$track_ips_v4 $1"
		fi
	}
	config_list_foreach "$1" track_ip mwan3_list_track_ips
	track_ips="$track_ips_v4"
	[ "$4" = "ipv6" ] && track_ips="$track_ips_v6"

	old_pids=$(pgrep -f "mwan3track $4 $1 ")
	old_pid=`echo mwan3track $4 $1 $2 $3 $track_ips`
	old_pid=$(pgrep -f "$old_pid")

	if [ "$old_pids" ] && [ "$old_pids" = "$old_pid" ]; then
		return
	fi

	# don't match device in case it changed from last launch
	if pids=$(pgrep -f "mwan3track $4 $1 "); then
		kill -TERM $pids > /dev/null 2>&1
		sleep 1
		kill -KILL $(pgrep -f "mwan3track $4 $1 ") > /dev/null 2>&1
	fi

	if [ -n "$track_ips" ]; then
		[ -x /usr/sbin/mwan3track ] && MWAN3_STARTUP=0 /usr/sbin/mwan3track $4 "$1" "$2" "$3" $track_ips &
	fi
}

mwan3_set_policy()
{
	local id iface family family_list metric probability weight device is_lowest is_offline IPT IPTR total_weight current update error

	is_lowest=0
	config_get iface "$1" interface
	config_get metric "$1" metric 1
	config_get weight "$1" weight 1

	[ -n "$iface" ] || return 0
	network_get_device device "$iface"
	[ "$metric" -gt $DEFAULT_LOWEST_METRIC ] && LOG warn "Member interface $iface has >$DEFAULT_LOWEST_METRIC metric. Not appending to policy" && return 0

	mwan3_get_iface_id id "$iface"

	[ -n "$id" ] || return 0

	config_get family_list "$iface" family "any"
	[ "$family_list" = "any" ] && family_list="ipv4 ipv6"
	for family in $family_list; do

	[ "$(mwan3_get_iface_hotplug_state "$iface" $family)" = "online" ]
	is_offline=$?

	if [ "$family" = "ipv4" ]; then
		IPT="$IPT4"
		IPTR="$IPT4R"
	elif [ "$family" = "ipv6" ]; then
		IPT="$IPT6"
		IPTR="$IPT6R"
	else
		continue
	fi
	current="$($IPT -S 2>/dev/null)"$'\n'
	update="*mangle"

	if [ "$family" = "ipv4" ] && [ $NEED_IPV4 -ne 0 ] && [ $is_offline -eq 0 ]; then
		if [ "$metric" -lt "$lowest_metric_v4" ]; then
			is_lowest=1
			total_weight_v4=$weight
			lowest_metric_v4=$metric
		elif [ "$metric" -eq "$lowest_metric_v4" ]; then
			total_weight_v4=$((total_weight_v4+weight))
			total_weight=$total_weight_v4
		else
			continue
		fi
	elif [ "$family" = "ipv6" ] && [ $NEED_IPV6 -ne 0 ] && [ $is_offline -eq 0 ]; then
		if [ "$metric" -lt "$lowest_metric_v6" ]; then
			is_lowest=1
			total_weight_v6=$weight
			lowest_metric_v6=$metric
		elif [ "$metric" -eq "$lowest_metric_v6" ]; then
			total_weight_v6=$((total_weight_v6+weight))
			total_weight=$total_weight_v6
		else
			continue
		fi
	else
		continue
	fi
	if [ $is_lowest -eq 1 ]; then
		mwan3_push_update -F "mwan3_policy_$policy"
		mwan3_push_update -A "mwan3_policy_$policy" \
				  -m mark --mark 0x0/$MMX_MASK \
				  -m comment --comment \"$iface $weight $weight\" \
				  -j MARK --set-xmark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK"
	elif [ $is_offline -eq 0 ]; then
		probability=$((weight*1000/total_weight))
		if [ "$probability" -lt 10 ]; then
			probability="0.00$probability"
		elif [ $probability -lt 100 ]; then
			probability="0.0$probability"
		elif [ $probability -lt 1000 ]; then
			probability="0.$probability"
		else
			probability="1"
		fi

		mwan3_push_update -I "mwan3_policy_$policy" \
				  -m mark --mark 0x0/$MMX_MASK \
				  -m statistic \
				  --mode random \
				  --probability "$probability" \
				  -m comment --comment \"$iface $weight $total_weight\" \
				  -j MARK --set-xmark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK"
	elif [ -n "$device" ]; then
		echo "$current" | grep -q "^-A mwan3_policy_$policy.*--comment .* [0-9]* [0-9]*" ||
			mwan3_push_update -I "mwan3_policy_$policy" \
					  -o "$device" \
					  -m mark --mark 0x0/$MMX_MASK \
					  -m comment --comment \"out $iface $device\" \
					  -j MARK --set-xmark $MMX_DEFAULT/$MMX_MASK
	fi
	mwan3_push_update COMMIT
	mwan3_push_update ""
	error=$(echo "$update" | $IPTR 2>&1) || LOG error "set_policy ($1): $error"

	done
}

mwan3_create_policies_iptables()
{
	local last_resort lowest_metric_v4 lowest_metric_v6 total_weight_v4 total_weight_v6 policy IPT current update error

	policy="$1"

	config_get last_resort "$1" last_resort unreachable

	if [ "$1" != "$(echo "$1" | cut -c1-15)" ]; then
		LOG warn "Policy $1 exceeds max of 15 chars. Not setting policy" && return 0
	fi

	for IPT in "$IPT4" "$IPT6"; do
		[ "$IPT" = "$IPT4" ] && [ $NEED_IPV4 -eq 0 ] && continue
		[ "$IPT" = "$IPT6" ] && [ $NEED_IPV6 -eq 0 ] && continue
		current="$($IPT -S 2>/dev/null)"$'\n'
		update="*mangle"
		if [ -n "${current##*-N mwan3_policy_$1$'\n'*}" ]; then
			mwan3_push_update -N "mwan3_policy_$1"
		fi

		mwan3_push_update -F "mwan3_policy_$1"

		case "$last_resort" in
			blackhole)
				mwan3_push_update -A "mwan3_policy_$1" \
						  -m mark --mark 0x0/$MMX_MASK \
						  -m comment --comment "blackhole" \
						  -j MARK --set-xmark $MMX_BLACKHOLE/$MMX_MASK
				;;
			default)
				mwan3_push_update -A "mwan3_policy_$1" \
						  -m mark --mark 0x0/$MMX_MASK \
						  -m comment --comment "default" \
						  -j MARK --set-xmark $MMX_DEFAULT/$MMX_MASK
				;;
			*)
				mwan3_push_update -A "mwan3_policy_$1" \
						  -m mark --mark 0x0/$MMX_MASK \
						  -m comment --comment "unreachable" \
						  -j MARK --set-xmark $MMX_UNREACHABLE/$MMX_MASK
				;;
		esac
		mwan3_push_update COMMIT
		mwan3_push_update ""
		if [ "$IPT" = "$IPT4" ]; then
			error=$(echo "$update" | $IPT4R 2>&1) || LOG error "create_policies_iptables ($1): $error"
		else
			error=$(echo "$update" | $IPT6R 2>&1) || LOG error "create_policies_iptables ($1): $error"
		fi
	done

	lowest_metric_v4=$DEFAULT_LOWEST_METRIC
	total_weight_v4=0

	lowest_metric_v6=$DEFAULT_LOWEST_METRIC
	total_weight_v6=0

	config_list_foreach "$1" use_member mwan3_set_policy
}

mwan3_set_policies_iptables()
{
	config_foreach mwan3_create_policies_iptables policy
}

mwan3_set_sticky_iptables()
{
	local id iface
	for iface in $(echo "$current" | grep "^-A $policy" | cut -s -d'"' -f2 | awk '{print $1}'); do
		if [ "$iface" = "$1" ]; then

			mwan3_get_iface_id id "$1"

			[ -n "$id" ] || return 0
			if [ -z "${current##*-N mwan3_iface_in_$1$'\n'*}" ]; then
				mwan3_push_update -I "mwan3_rule_$rule" \
						  -m mark --mark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK" \
						  -m set ! --match-set "mwan3_sticky_$rule" src,src \
						  -j MARK --set-xmark "0x0/$MMX_MASK"
				mwan3_push_update -I "mwan3_rule_$rule" \
						  -m mark --mark "0/$MMX_MASK" \
						  -j MARK --set-xmark "$(mwan3_id2mask id MMX_MASK)/$MMX_MASK"
			fi
		fi
	done
}

mwan3_set_user_iptables_rule()
{
	local ipset family proto policy src_ip src_port src_iface src_dev
	local sticky dest_ip dest_port use_policy timeout policy
	local global_logging rule_logging loglevel rule_policy rule ipv

	rule="$1"
	ipv="$2"
	rule_policy=0
	config_get sticky "$1" sticky 0
	config_get timeout "$1" timeout 600
	config_get ipset "$1" ipset
	config_get proto "$1" proto all
	config_get src_ip "$1" src_ip
	config_get src_iface "$1" src_iface
	config_get src_port "$1" src_port
	config_get dest_ip "$1" dest_ip
	config_get dest_port "$1" dest_port
	config_get use_policy "$1" use_policy
	config_get family "$1" family "any"
	config_get rule_logging "$1" logging 0
	config_get global_logging globals logging 0
	config_get loglevel globals loglevel notice

	[ "$family" = "any" ] && family="$ipv"

	if [ -n "$src_iface" ]; then
		network_get_device src_dev "$src_iface"
		if [ -z "$src_dev" ]; then
			LOG notice "could not find device corresponding to src_iface $src_iface for rule $1"
			return
		fi
	fi

	[ -z "$dest_ip" ] && unset dest_ip
	[ -z "$src_ip" ] && unset src_ip
	[ -z "$ipset" ] && unset ipset
	[ -z "$src_port" ] && unset src_port
	[ -z "$dest_port" ] && unset dest_port
	if [ "$proto" != 'tcp' ] && [ "$proto" != 'udp' ]; then
		[ -n "$src_port" ] && {
			LOG warn "src_port set to '$src_port' but proto set to '$proto' not tcp or udp. src_port will be ignored"
		}

		[ -n "$dest_port" ] && {
			LOG warn "dest_port set to '$dest_port' but proto set to '$proto' not tcp or udp. dest_port will be ignored"
		}
		unset src_port
		unset dest_port
	fi

	if [ "$1" != "$(echo "$1" | cut -c1-15)" ]; then
		LOG warn "Rule $1 exceeds max of 15 chars. Not setting rule" && return 0
	fi

	if [ -n "$ipset" ]; then
		ipset="-m set --match-set $ipset dst"
	fi

	if [ -z "$use_policy" ]; then
		return
	fi

	if [ "$use_policy" = "default" ]; then
		policy="MARK --set-xmark $MMX_DEFAULT/$MMX_MASK"
	elif [ "$use_policy" = "unreachable" ]; then
		policy="MARK --set-xmark $MMX_UNREACHABLE/$MMX_MASK"
	elif [ "$use_policy" = "blackhole" ]; then
		policy="MARK --set-xmark $MMX_BLACKHOLE/$MMX_MASK"
	else
		rule_policy=1
		policy="mwan3_policy_$use_policy"
		if [ "$sticky" -eq 1 ]; then
			if [ $NEED_IPV4 -ne 0 ] || [ $NEED_IPV6 -ne 0 ]; then
				$IPS -! create "mwan3_sticky_$rule" list:set
				[ $NEED_IPV4 -ne 0 ] && {
					$IPS -! create "mwan3_sticky_v4_$rule" \
					     hash:ip,mark markmask "$MMX_MASK" \
					     timeout "$timeout"
					$IPS -! add "mwan3_sticky_$rule" "mwan3_sticky_v4_$rule"
				}
				[ $NEED_IPV6 -ne 0 ] && {
					$IPS -! create "mwan3_sticky_v6_$rule" \
					     hash:ip,mark markmask "$MMX_MASK" \
					     timeout "$timeout" family inet6
					$IPS -! add "mwan3_sticky_$rule" "mwan3_sticky_v6_$rule"
				}
			fi
		fi
	fi

	[ "$ipv" = "ipv4" ] && [ $NEED_IPV4 -eq 0 ] && return
	[ "$ipv" = "ipv6" ] && [ $NEED_IPV6 -eq 0 ] && return
	[ "$family" = "ipv4" ] && [ "$ipv" = "ipv6" ] && return
	[ "$family" = "ipv6" ] && [ "$ipv" = "ipv4" ] && return

	if [ $rule_policy -eq 1 ] && [ -n "${current##*-N $policy$'\n'*}" ]; then
		mwan3_push_update -N "$policy"
	fi

	if [ $rule_policy -eq 1 ] && [ "$sticky" -eq 1 ]; then
		if [ -n "${current##*-N mwan3_rule_$1$'\n'*}" ]; then
			mwan3_push_update -N "mwan3_rule_$1"
		fi

		mwan3_push_update -F "mwan3_rule_$1"
		config_foreach mwan3_set_sticky_iptables interface $ipv


		mwan3_push_update -A "mwan3_rule_$1" \
				  -m mark --mark 0/$MMX_MASK \
				  -j "$policy"
		mwan3_push_update -A "mwan3_rule_$1" \
				  -m mark ! --mark 0xfc00/0xfc00 \
				  -j SET --del-set "mwan3_sticky_$rule" src,src
		mwan3_push_update -A "mwan3_rule_$1" \
				  -m mark ! --mark 0xfc00/0xfc00 \
				  -j SET --add-set "mwan3_sticky_$rule" src,src
		policy="mwan3_rule_$1"
	fi
	if [ "$global_logging" = "1" ] && [ "$rule_logging" = "1" ]; then
		mwan3_push_update -A mwan3_rules \
				  -p "$proto" \
				  ${src_ip:+-s} $src_ip \
				  ${src_dev:+-i} $src_dev \
				  ${dest_ip:+-d} $dest_ip \
				  $ipset \
				  ${src_port:+-m} ${src_port:+multiport} ${src_port:+--sports} $src_port \
				  ${dest_port:+-m} ${dest_port:+multiport} ${dest_port:+--dports} $dest_port \
				  -m mark --mark 0/$MMX_MASK \
				  -m comment --comment "$1" \
				  -j LOG --log-level "$loglevel" --log-prefix "MWAN3($1)"
	fi

	mwan3_push_update -A mwan3_rules \
			  -p "$proto" \
			  ${src_ip:+-s} $src_ip \
			  ${src_dev:+-i} $src_dev \
			  ${dest_ip:+-d} $dest_ip \
			  $ipset \
			  ${src_port:+-m} ${src_port:+multiport} ${src_port:+--sports} $src_port \
			  ${dest_port:+-m} ${dest_port:+multiport} ${dest_port:+--dports} $dest_port \
			  -m mark --mark 0/$MMX_MASK \
			  -j $policy

}

mwan3_set_user_iface_rules()
{
	local current iface update family family_list error device is_src_iface
	iface=$1
	device=$2

	if [ -z "$device" ]; then
		LOG notice "set_user_iface_rules: could not find device corresponding to iface $iface"
		return
	fi

	config_get family_list "$iface" family "any"
	[ "$family_list" = "any" ] && family_list="ipv4 ipv6"
	for family in $family_list; do

	if [ "$family" = "ipv4" ]; then
		IPT="$IPT4"
		IPTR="$IPT4R"
	elif [ "$family" = "ipv6" ]; then
		IPT="$IPT6"
		IPTR="$IPT6R"
	else
		continue
	fi
	$IPT -S 2>/dev/null | grep -q "^-A mwan3_rules.*-i $device" && return

	is_src_iface=0

	iface_rule()
	{
		local src_iface
		config_get src_iface "$1" src_iface
		[ "$src_iface" = "$iface" ] && is_src_iface=1
	}
	config_foreach iface_rule rule
	[ $is_src_iface -eq 1 ] && mwan3_set_user_rules

	done
}

mwan3_set_user_rules()
{
	local IPT IPTR ipv
	local current update error

	for ipv in ipv4 ipv6; do
		if [ "$ipv" = "ipv4" ] && [ $NEED_IPV4 -ne 0 ]; then
			IPT="$IPT4"
			IPTR="$IPT4R"
		elif [ "$ipv" = "ipv6" ] && [ $NEED_IPV6 -ne 0 ]; then
			IPT="$IPT6"
			IPTR="$IPT6R"
		else
			continue
		fi
		update="*mangle"
		current="$($IPT -S 2>/dev/null)"$'\n'


		if [ -n "${current##*-N mwan3_rules*}" ]; then
			mwan3_push_update -N "mwan3_rules"
		fi

		mwan3_push_update -F mwan3_rules

		config_foreach mwan3_set_user_iptables_rule rule "$ipv"

		mwan3_push_update COMMIT
		mwan3_push_update ""
		error=$(echo "$update" | $IPTR 2>&1) || {
			echo "$update" | while read line; do
				$IPT $line >>/dev/null 2>&1 || LOG error "set_user_rules: fail/skip: $IPT $line"
			done
			LOG error "set_user_rules: $error"
		}
	done
}

mwan3_set_iface_hotplug_state() {
	local iface=$1
	local state=$2
	local family=$3

	echo "$state" > "$MWAN3_STATUS_DIR/iface_state/$iface.$family"
}

mwan3_state_is_changed() {
	local old_state_sum=$( cat "$MWAN3_STATUS_DIR/iface_state.sum" 2>/dev/null )
	local new_state_sum=$( ( ls /var/run/mwan3/iface_state/; cat /var/run/mwan3/iface_state/* 2>/dev/null ) | md5sum | head -c32 )
	if [ "$old_state_sum" = "$new_state_sum" ]; then
		return 1
	fi
	echo "$new_state_sum" > "$MWAN3_STATUS_DIR/iface_state.sum"
	return 0
}

mwan3_get_iface_hotplug_state() {
	local iface=$1
	local family=$2

	cat "$MWAN3_STATUS_DIR/iface_state/$iface.$family" 2>/dev/null || echo "offline"
}

mwan3_report_iface_status()
{
	local device result track_ips tracking IP IPT family family_list
	local track_ips_v4 track_ips_v6
	local error

	mwan3_get_iface_id id "$1"
	network_get_device device "$1"
	config_get enabled "$1" enabled 0
	config_get family_list "$1" family "any"

	mwan3_list_track_ips()
	{
		if echo $1 | grep -q ":"; then
			track_ips_v6="$track_ips_v6 $1"
		elif echo $1 | grep -qE "$IPv4_REGEX"; then
			track_ips_v4="$track_ips_v4 $1"
		else
			track_ips_v6="$track_ips_v6 $1"
			track_ips_v4="$track_ips_v4 $1"
		fi
	}
	config_list_foreach "$1" track_ip mwan3_list_track_ips

	[ "$family_list" = "any" ] && family_list="ipv4 ipv6"
	for family in $family_list; do

	if [ "$family" = "ipv4" ]; then
		IP="$IP4"
		IPT="$IPT4"
	elif [ "$family" = "ipv6" ]; then
		IP="$IP6"
		IPT="$IPT6"
	else
		continue
	fi

	if [ -z "$id" ] || [ -z "$device" ]; then
		result="offline"
	else
		error=0
		[ -n "$($IP rule | awk '$1 == "'$((id+1000)):'"')" ] || error=$((error+1))
		[ -n "$($IP rule | awk '$1 == "'$((id+2000)):'"')" ] || error=$((error+2))
		[ -n "$($IPT -S mwan3_iface_in_$1 2> /dev/null)" ] || error=$((error+4))
		[ -n "$($IP route list table $id default dev $device 2> /dev/null)" ] || error=$((error+8))
	fi

	if [ "$result" = "offline" ]; then
		:
	elif [ $error -eq 0 ]; then
		online=$(get_online_time "$1" "$family")
		network_get_uptime uptime "$1"
		online="$(printf '%02dh:%02dm:%02ds\n' $((online/3600)) $((online%3600/60)) $((online%60)))"
		uptime="$(printf '%02dh:%02dm:%02ds\n' $((uptime/3600)) $((uptime%3600/60)) $((uptime%60)))"
		result="$(mwan3_get_iface_hotplug_state $1 $family) $online, uptime $uptime"
	elif [ $error -gt 0 ] && [ $error -ne 15 ]; then
		result="error (${error})"
	elif [ "$enabled" = "1" ]; then
		result="offline"
	else
		result="disabled"
	fi

	track_ips="$track_ips_v4"
	[ "$family" = "ipv6" ] && track_ips="$track_ips_v6"

	if [ -n "$track_ips" ]; then
		if [ -n "$(pgrep -f "mwan3track $family $1 $device")" ]; then
			tracking="active"
		else
			tracking="down"
		fi
	else
		tracking="not enabled"
	fi

	echo " interface $1($family) is $result and tracking is $tracking"

	done
}

mwan3_report_policies()
{
	local ipt="$1"
	local policy="$2"

	local percent total_weight weight iface

	total_weight=$($ipt -S "$policy" 2>/dev/null | grep -v '.*--comment "out .*" .*$' | cut -s -d'"' -f2 | head -1 | awk '{print $3}')

	if [ -n "${total_weight##*[!0-9]*}" ]; then
		for iface in $($ipt -S "$policy" 2>/dev/null | grep -v '.*--comment "out .*" .*$' | cut -s -d'"' -f2 | awk '{print $1}'); do
			weight=$($ipt -S "$policy" 2>/dev/null | grep -v '.*--comment "out .*" .*$' | cut -s -d'"' -f2 | awk '$1 == "'$iface'"' | awk '{print $2}')
			percent=$((weight*100/total_weight))
			echo " $iface ($percent%)"
		done
	else
		echo " $($ipt -S "$policy" 2>/dev/null | grep -v '.*--comment "out .*" .*$' | sed '/.*--comment \([^ ]*\) .*$/!d;s//\1/;q')"
	fi
}

mwan3_report_policies_v4()
{
	local policy

	for policy in $($IPT4 -S 2>/dev/null | awk '{print $2}' | grep mwan3_policy_ | sort -u); do
		echo "$policy:" | sed 's/mwan3_policy_//'
		mwan3_report_policies "$IPT4" "$policy"
	done
}

mwan3_report_policies_v6()
{
	local policy

	for policy in $($IPT6 -S 2>/dev/null | awk '{print $2}' | grep mwan3_policy_ | sort -u); do
		echo "$policy:" | sed 's/mwan3_policy_//'
		mwan3_report_policies "$IPT6" "$policy"
	done
}

mwan3_report_rules_v4()
{
	if [ -n "$($IPT4 -S mwan3_rules 2> /dev/null)" ]; then
		$IPT4 -L mwan3_rules -n -v 2> /dev/null | tail -n+3 | sed 's/mark.*//' | sed 's/mwan3_policy_/- /' | sed 's/mwan3_rule_/S /'
	fi
}

mwan3_report_rules_v6()
{
	if [ -n "$($IPT6 -S mwan3_rules 2> /dev/null)" ]; then
		$IPT6 -L mwan3_rules -n -v 2> /dev/null | tail -n+3 | sed 's/mark.*//' | sed 's/mwan3_policy_/- /' | sed 's/mwan3_rule_/S /'
	fi
}

mwan3_flush_conntrack()
{
	local interface="$1"
	local action="$2"

	handle_flush() {
		local flush_conntrack="$1"
		local action="$2"

		if [ "$action" = "$flush_conntrack" ]; then
			echo f > ${CONNTRACK_FILE}
			LOG info "Connection tracking flushed for interface '$interface' on action '$action'"
		fi
	}

	if [ -e "$CONNTRACK_FILE" ]; then
		config_list_foreach "$interface" flush_conntrack handle_flush "$action"
	fi
}

mwan3_track_clean()
{
	rm -rf "${MWAN3_STATUS_DIR:?}/${1}.${2}" &> /dev/null
	rmdir "$MWAN3_STATUS_DIR" 2>/dev/null
}

mwan3_delay_hotplug_call()
{
	local line="DELAY_HOTPLUG=$DELAY_HOTPLUG MWAN3_STARTUP=$MWAN3_STARTUP ACTION=$ACTION INTERFACE=$INTERFACE DEVICE=$DEVICE FAMILY=$FAMILY sh /etc/hotplug.d/iface/15-mwan3"
	echo $line >>$MWAN3_STATUS_DIR/iface_hotplug.cmd
	(
	sleep 11
	last_time=$(date -r $MWAN3_STATUS_DIR/iface_hotplug.cmd +%s)
	now_time=$(date +%s)
	if test "$((now_time-last_time))" -gt 9; then
		mv $MWAN3_STATUS_DIR/iface_hotplug.cmd $MWAN3_STATUS_DIR/iface_hotplug.cmd.tmp && {
			NR=$(cat $MWAN3_STATUS_DIR/iface_hotplug.cmd.tmp | wc -l)
			if test $NR -ge 8; then
				rm -f $MWAN3_STATUS_DIR/iface_hotplug.cmd*
				/etc/init.d/mwan3 restart
			else
				cat $MWAN3_STATUS_DIR/iface_hotplug.cmd.tmp | while read cmd; do
					env -i $cmd
				done
				rm -f $MWAN3_STATUS_DIR/iface_hotplug.cmd.tmp
			fi
		}
	fi
	) &
}
