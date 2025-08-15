#!/bin/bash
# macOS IP & MAC Address Changer (Fixed Version by NHT & GPT)
# Hỗ trợ macOS Sonoma+, tự động tính subnet từ netmask hex

set -e

# Màu
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_status()  { echo -e "${BLUE}[THÔNG BÁO]${NC} $1"; }
print_success() { echo -e "${GREEN}[THÀNH CÔNG]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[CẢNH BÁO]${NC} $1"; }
print_error()   { echo -e "${RED}[LỖI]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Cần quyền root. Dùng: sudo $0"
        exit 1
    fi
}

# Convert netmask hex -> dotted
hex_to_dotted() {
    local hex=$1
    local mask=$(printf "%08x" $((hex)))
    echo "$((0x${mask:0:2})).$((0x${mask:2:2})).$((0x${mask:4:2})).$((0x${mask:6:2}))"
}

get_wifi_interface() {
    WIFI_INTERFACE=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/ {getline; print $2}')
    if [ -z "$WIFI_INTERFACE" ]; then
        print_error "Không tìm thấy Wi-Fi interface"
        exit 1
    fi
    print_status "Giao diện Wi-Fi: $WIFI_INTERFACE"
}

get_network_info() {
    CURRENT_IP=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $2}')
    RAW_NETMASK=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $4}')
    GATEWAY=$(route -n get default | grep gateway | awk '{print $2}')

    if [[ $RAW_NETMASK == 0x* ]]; then
        NETMASK=$(hex_to_dotted $RAW_NETMASK)
    else
        NETMASK=$RAW_NETMASK
    fi

    print_status "IP hiện tại: $CURRENT_IP"
    print_status "Netmask: $NETMASK"
    print_status "Gateway: $GATEWAY"
}

calc_subnet() {
    IFS='.' read -r i1 i2 i3 i4 <<< "$CURRENT_IP"
    IFS='.' read -r m1 m2 m3 m4 <<< "$NETMASK"

    NETWORK_ADDR="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).$((i4 & m4))"

    CIDR=$(ipcalc_cidr $NETMASK)
    IP_RANGE_START="$i1.$i2.$i3.2"
    IP_RANGE_END="$i1.$i2.$i3.254"

    print_status "Dải mạng: $NETWORK_ADDR/$CIDR"
    print_status "IP usable: $IP_RANGE_START - $IP_RANGE_END"
}

ipcalc_cidr() {
    local mask=$1
    IFS='.' read -r a b c d <<< "$mask"
    bin=$(printf "%08d%08d%08d%08d\n" $(bc <<< "obase=2;$a") $(bc <<< "obase=2;$b") $(bc <<< "obase=2;$c") $(bc <<< "obase=2;$d"))
    echo -n "${bin//0/}" | wc -c | tr -d ' '
}

set_ip() {
    read -p "Random IP (r) hay nhập thủ công (m)? (r/m): " mode
    if [[ $mode =~ ^[Mm]$ ]]; then
        read -p "Nhập IP mới: " NEW_IP
    else
        RANDOM_OCTET=$((RANDOM % 200 + 50))
        IFS='.' read -r i1 i2 i3 i4 <<< "$CURRENT_IP"
        NEW_IP="$i1.$i2.$i3.$RANDOM_OCTET"
    fi
    print_status "IP mới: $NEW_IP"
}

set_mac() {
    read -p "Random MAC (r) hay nhập thủ công (m)? (r/m): " mode
    if [[ $mode =~ ^[Mm]$ ]]; then
        read -p "Nhập MAC (xx:xx:xx:xx:xx:xx): " MAC_ADDR
    else
        MAC_ADDR="02:$(printf '%02x' $((RANDOM%256))):$(printf '%02x' $((RANDOM%256))):$(printf '%02x' $((RANDOM%256))):$(printf '%02x' $((RANDOM%256))):$(printf '%02x' $((RANDOM%256)))"
    fi
    print_status "MAC mới: $MAC_ADDR"
}

change_ip() {
    print_status "Đang đổi IP..."
    networksetup -setmanual "Wi-Fi" $NEW_IP $NETMASK $GATEWAY
    sleep 2
    VERIFY=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $2}')
    [[ "$VERIFY" == "$NEW_IP" ]] && print_success "Đổi IP thành $NEW_IP" || print_error "Đổi IP fail"
}

change_mac() {
    print_status "Đang đổi MAC..."
    networksetup -setairportpower $WIFI_INTERFACE off
    sleep 2

    # Xoá IP cũ để tránh lỗi ioctl
    ifconfig $WIFI_INTERFACE inet 0.0.0.0 down
    sleep 1

    ifconfig $WIFI_INTERFACE ether $MAC_ADDR
    sleep 1

    networksetup -setairportpower $WIFI_INTERFACE on
    sleep 4

    VERIFY=$(ifconfig $WIFI_INTERFACE | grep ether | awk '{print $2}')
    if [ "$VERIFY" == "$MAC_ADDR" ]; then
        print_success "Đổi MAC thành $MAC_ADDR"
    else
        print_error "Đổi MAC thất bại (SIP có thể block)"
    fi
}


restore_dhcp() {
    networksetup -setdhcp "Wi-Fi"
    print_success "Khôi phục DHCP thành công"
}

show_status() {
    echo -e "\n${BLUE}=== THÔNG TIN MẠNG HIỆN TẠI ===${NC}"
    echo "IP: $(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $2}')"
    echo "MAC: $(ifconfig $WIFI_INTERFACE | grep ether | awk '{print $2}')"
    echo "Gateway: $GATEWAY"
    echo "=================================\n"
}

menu() {
    echo -e "${BLUE}=== Menu ===${NC}"
    echo "1. Đổi cả IP + MAC"
    echo "2. Đổi IP"
    echo "3. Đổi MAC"
    echo "4. Reset DHCP"
    echo "5. Xem thông tin"
    echo "6. Thoát"
    read -p "Chọn (1-6): " c
    case $c in
        1) get_network_info; calc_subnet; set_ip; set_mac; change_mac; change_ip; show_status;;
        2) get_network_info; calc_subnet; set_ip; change_ip; show_status;;
        3) set_mac; change_mac; show_status;;
        4) restore_dhcp; show_status;;
        5) get_network_info; show_status;;
        6) exit 0;;
        *) print_error "Sai lựa chọn";;
    esac
}

main() {
    check_root
    get_wifi_interface
    while true; do menu; done
}

main
