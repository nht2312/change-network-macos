#!/bin/bash

# macOS IP & MAC Address Changer Tool (Cập nhật)
# Tự động hoặc thủ công thay đổi IP và MAC address, tương tự VMware Network Editor

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[THÔNG BÁO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[THÀNH CÔNG]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[CẢNH BÁO]${NC} $1"
}

print_error() {
    echo -e "${RED}[LỖI]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Công cụ cần quyền root để thay đổi cài đặt mạng"
        echo "Chạy lại với: sudo $0"
        exit 1
    fi
}

# Get current WiFi interface
get_wifi_interface() {
    WIFI_INTERFACE=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/ {getline; print $2}')
    if [ -z "$WIFI_INTERFACE" ]; then
        print_error "Không tìm thấy giao diện Wi-Fi"
        exit 1
    fi
    print_status "Giao diện Wi-Fi: $WIFI_INTERFACE"
}

# Get current network info
get_current_network_info() {
    print_status "Đang lấy thông tin mạng hiện tại..."
    
    CURRENT_IP=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $2}')
    NETMASK=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $4}')
    GATEWAY=$(route -n get default | grep gateway | awk '{print $2}')
    
    if [ -z "$CURRENT_IP" ] || [ -z "$GATEWAY" ]; then
        print_error "Không thể lấy thông tin mạng. Kiểm tra kết nối Wi-Fi"
        exit 1
    fi
    
    print_status "IP hiện tại: $CURRENT_IP"
    print_status "Gateway: $GATEWAY"
    print_status "Netmask: $NETMASK"
}

# Calculate network range and CIDR
calculate_network_range() {
    # Convert netmask to CIDR
    CIDR=$(echo $NETMASK | awk -F. '{
        split($0, octets, ".")
        cidr = 0
        for (i in octets) {
            mask = octets[i]
            while (mask > 0) {
                cidr += mask % 2
                mask = int(mask / 2)
            }
        }
        print cidr
    }')
    
    # Get network address
    IFS='.' read -r i1 i2 i3 i4 <<< "$CURRENT_IP"
    IFS='.' read -r m1 m2 m3 m4 <<< "$NETMASK"
    
    NETWORK_ADDR="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).$((i4 & m4))"
    
    # Calculate usable IP range
    IP_RANGE_START="$NETWORK_ADDR.2"
    IP_RANGE_END="$NETWORK_ADDR.254"  # Giả định /24, điều chỉnh cho CIDR khác
    if [ "$CIDR" -lt 24 ]; then
        print_warning "Hỗ trợ hạn chế cho subnet lớn (/16 hoặc thấp hơn). Sử dụng IP thủ công nếu cần."
        IP_RANGE_START="$NETWORK_ADDR.1.2"
        IP_RANGE_END="$NETWORK_ADDR.254.254"
    fi
    
    print_status "Dải mạng: $NETWORK_ADDR/$CIDR"
    print_status "IP có thể sử dụng: $IP_RANGE_START - $IP_RANGE_END"
}

# Generate or set manual IP
set_ip() {
    read -p "Bạn muốn tạo IP ngẫu nhiên (r) hay nhập thủ công (m)? (r/m): " ip_mode
    if [[ $ip_mode =~ ^[Mm]$ ]]; then
        read -p "Nhập IP mới (ví dụ: 192.168.1.100): " NEW_IP
        if ! [[ $NEW_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            print_error "IP không hợp lệ"
            set_ip
        fi
    else
        IFS='.' read -r start1 start2 start3 start4 <<< "$IP_RANGE_START"
        IFS='.' read -r end1 end2 end3 end4 <<< "$IP_RANGE_END"
        
        RANDOM_OCTET=$((RANDOM % (254 - 2 + 1) + 2))  # Từ 2 đến 254 cho /24
        NEW_IP="$start1.$start2.$start3.$RANDOM_OCTET"
        
        while [ "$NEW_IP" = "$CURRENT_IP" ] || [ "$NEW_IP" = "$GATEWAY" ]; do
            RANDOM_OCTET=$((RANDOM % (254 - 2 + 1) + 2))
            NEW_IP="$start1.$start2.$start3.$RANDOM_OCTET"
        done
    fi
    
    # Kiểm tra xung đột IP
    ping -c 1 -W 1 $NEW_IP > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        print_warning "IP $NEW_IP đang được sử dụng. Tạo lại..."
        set_ip
    else
        print_status "IP mới: $NEW_IP"
    fi
}

# Generate or set manual MAC
set_mac() {
    read -p "Bạn muốn tạo MAC ngẫu nhiên (r) hay nhập thủ công (m)? (r/m): " mac_mode
    if [[ $mac_mode =~ ^[Mm]$ ]]; then
        read -p "Nhập MAC mới (ví dụ: 02:xx:xx:xx:xx:xx): " MAC_ADDR
        if ! [[ $MAC_ADDR =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
            print_error "MAC không hợp lệ"
            set_mac
        fi
    else
        FIRST_OCTET="02"  # Locally administered
        MAC_ADDR="$FIRST_OCTET"
        for i in {1..5}; do
            MAC_ADDR="$MAC_ADDR:$(printf '%02x' $((RANDOM % 256)))"
        done
    fi
    print_status "MAC mới: $MAC_ADDR"
}

# Change MAC address with SIP warning
change_mac_address() {
    print_status "Đang thay đổi MAC address..."
    print_warning "Trên macOS Sonoma+, SIP có thể chặn thay đổi. Nếu thất bại, tắt SIP tạm thời."
    
    networksetup -setairportpower $WIFI_INTERFACE off
    sleep 3
    
    ifconfig $WIFI_INTERFACE ether $MAC_ADDR
    
    networksetup -setairportpower $WIFI_INTERFACE on
    sleep 5
    
    VERIFY_MAC=$(ifconfig $WIFI_INTERFACE | grep ether | awk '{print $2}')
    if [ "$VERIFY_MAC" = "$MAC_ADDR" ]; then
        print_success "Đã thay đổi MAC thành: $MAC_ADDR"
    else
        print_error "Thay đổi MAC thất bại (có thể do SIP). Kiểm tra hoặc dùng tool khác."
    fi
}

# Change IP address
change_ip_address() {
    print_status "Đang thay đổi IP address..."
    
    networksetup -setmanual "Wi-Fi" $NEW_IP $NETMASK $GATEWAY
    sleep 3
    
    VERIFY_IP=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $2}')
    if [ "$VERIFY_IP" = "$NEW_IP" ]; then
        print_success "Đã thay đổi IP thành: $NEW_IP"
    else
        print_error "Thay đổi IP thất bại"
    fi
}

# Restore DHCP (tương tự bridged mode)
restore_dhcp() {
    print_status "Khôi phục cấu hình DHCP (tương tự bridged mode)..."
    networksetup -setdhcp "Wi-Fi"
    print_success "Đã khôi phục DHCP"
}

# Show current status
show_status() {
    echo -e "\n${BLUE}=== THÔNG TIN MẠNG HIỆN TẠI ===${NC}"
    CURRENT_IP_STATUS=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $2}')
    CURRENT_MAC_STATUS=$(ifconfig $WIFI_INTERFACE | grep ether | awk '{print $2}')
    
    echo "Giao diện: $WIFI_INTERFACE"
    echo "IP Address: $CURRENT_IP_STATUS"
    echo "MAC Address: $CURRENT_MAC_STATUS"
    echo "Gateway: $GATEWAY"
    echo -e "${BLUE}=================================${NC}\n"
}

# Main menu (giống editor hơn)
show_menu() {
    echo -e "\n${BLUE}=== Công Cụ Thay Đổi Mạng macOS (Cập Nhật) ===${NC}"
    echo "1. Thay đổi cả IP và MAC (thủ công hoặc ngẫu nhiên)"
    echo "2. Chỉ thay đổi IP (static mode)"
    echo "3. Chỉ thay đổi MAC"
    echo "4. Khôi phục DHCP (bridged mode)"
    echo "5. Hiển thị thông tin mạng hiện tại"
    echo "6. Thoát"
    echo -e "${BLUE}=================================${NC}"
    read -p "Chọn tùy chọn (1-6): " choice
}

# Main function
main() {
    check_root
    get_wifi_interface
    
    while true; do
        show_menu
        
        case $choice in
            1)
                get_current_network_info
                calculate_network_range
                set_ip
                set_mac
                
                print_warning "Sắp thay đổi:"
                echo "  IP: $CURRENT_IP → $NEW_IP"
                echo "  MAC: $(ifconfig $WIFI_INTERFACE | grep ether | awk '{print $2}') → $MAC_ADDR"
                read -p "Tiếp tục? (y/N): " confirm
                
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    change_mac_address
                    change_ip_address
                    show_status
                fi
                ;;
            2)
                get_current_network_info
                calculate_network_range
                set_ip
                
                print_warning "Sắp thay đổi IP: $CURRENT_IP → $NEW_IP"
                read -p "Tiếp tục? (y/N): " confirm
                
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    change_ip_address
                    show_status
                fi
                ;;
            3)
                set_mac
                
                print_warning "Sắp thay đổi MAC: $(ifconfig $WIFI_INTERFACE | grep ether | awk '{print $2}') → $MAC_ADDR"
                read -p "Tiếp tục? (y/N): " confirm
                
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    change_mac_address
                    show_status
                fi
                ;;
            4)
                restore_dhcp
                show_status
                ;;
            5)
                get_current_network_info
                show_status
                ;;
            6)
                print_success "Tạm biệt!"
                exit 0
                ;;
            *)
                print_error "Lựa chọn không hợp lệ"
                ;;
        esac
        
        echo -e "\nNhấn Enter để tiếp tục..."
        read
    done
}

# Run main function
main
