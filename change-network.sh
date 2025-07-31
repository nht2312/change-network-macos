#!/bin/bash

# macOS IP & MAC Address Changer Tool
# Tự động thay đổi IP và MAC address dựa trên dải mạng hiện tại

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Tool này cần quyền root để thay đổi network settings"
        echo "Chạy lại với: sudo $0"
        exit 1
    fi
}

# Get current WiFi interface
get_wifi_interface() {
    WIFI_INTERFACE=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/ {getline; print $2}')
    if [ -z "$WIFI_INTERFACE" ]; then
        print_error "Không tìm thấy WiFi interface"
        exit 1
    fi
    print_status "WiFi Interface: $WIFI_INTERFACE"
}

# Get current network info
get_current_network_info() {
    print_status "Đang lấy thông tin mạng hiện tại..."
    
    # Get current IP and subnet
    CURRENT_IP=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $2}')
    NETMASK=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $4}')
    GATEWAY=$(route -n get default | grep gateway | awk '{print $2}')
    
    if [ -z "$CURRENT_IP" ] || [ -z "$GATEWAY" ]; then
        print_error "Không thể lấy thông tin mạng. Kiểm tra kết nối WiFi"
        exit 1
    fi
    
    print_status "IP hiện tại: $CURRENT_IP"
    print_status "Gateway: $GATEWAY"
    print_status "Netmask: $NETMASK"
}

# Calculate network range
calculate_network_range() {
    # Convert netmask to CIDR
    CIDR=$(echo $NETMASK | awk -F. '{
        split($0, octets, ".")
        for (i in octets) {
            mask = octets[i]
            for (j = 7; j >= 0; j--) {
                if (and(mask, 2^j) != 0) cidr++
                else break
            }
        }
        print cidr
    }')
    
    # Get network address
    IFS='.' read -r i1 i2 i3 i4 <<< "$CURRENT_IP"
    IFS='.' read -r m1 m2 m3 m4 <<< "$NETMASK"
    
    NETWORK_ADDR="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).$((i4 & m4))"
    
    # Calculate usable IP range (excluding network and broadcast addresses)
    if [ "$CIDR" -eq 24 ]; then
        IP_RANGE_START="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).2"
        IP_RANGE_END="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).254"
    elif [ "$CIDR" -eq 16 ]; then
        IP_RANGE_START="$((i1 & m1)).$((i2 & m2)).1.2"
        IP_RANGE_END="$((i1 & m1)).$((i2 & m2)).254.254"
    else
        # For other subnet masks, use a simple range
        IP_RANGE_START="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).2"
        IP_RANGE_END="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).254"
    fi
    
    print_status "Dải mạng: $NETWORK_ADDR/$CIDR"
    print_status "IP có thể sử dụng: $IP_RANGE_START - $IP_RANGE_END"
}

# Generate random IP in network range
generate_random_ip() {
    IFS='.' read -r start1 start2 start3 start4 <<< "$IP_RANGE_START"
    IFS='.' read -r end1 end2 end3 end4 <<< "$IP_RANGE_END"
    
    # Generate random IP within range
    if [ "$CIDR" -eq 24 ]; then
        # /24 network
        RANDOM_OCTET=$((RANDOM % (end4 - start4) + start4))
        NEW_IP="$start1.$start2.$start3.$RANDOM_OCTET"
    else
        # Other networks - simple random in last octet
        RANDOM_OCTET=$((RANDOM % 253 + 2))
        NEW_IP="$start1.$start2.$start3.$RANDOM_OCTET"
    fi
    
    # Make sure we don't use the same IP
    while [ "$NEW_IP" = "$CURRENT_IP" ] || [ "$NEW_IP" = "$GATEWAY" ]; do
        RANDOM_OCTET=$((RANDOM % 253 + 2))
        NEW_IP="$start1.$start2.$start3.$RANDOM_OCTET"
    done
    
    print_status "IP mới được tạo: $NEW_IP"
}

# Generate random MAC address
generate_random_mac() {
    # Generate a random MAC with locally administered bit set
    # First octet: x2, x6, xA, xE (locally administered unicast)
    FIRST_OCTET="02"
    
    MAC_ADDR="$FIRST_OCTET"
    for i in {1..5}; do
        MAC_ADDR="$MAC_ADDR:$(printf '%02x' $((RANDOM % 256)))"
    done
    
    print_status "MAC address mới: $MAC_ADDR"
}

# Change MAC address
change_mac_address() {
    print_status "Đang thay đổi MAC address..."
    
    # Disable WiFi
    networksetup -setairportpower $WIFI_INTERFACE off
    sleep 2
    
    # Change MAC address
    ifconfig $WIFI_INTERFACE ether $MAC_ADDR
    
    # Enable WiFi
    networksetup -setairportpower $WIFI_INTERFACE on
    sleep 3
    
    print_success "Đã thay đổi MAC address thành: $MAC_ADDR"
}

# Change IP address
change_ip_address() {
    print_status "Đang thay đổi IP address..."
    
    # Set static IP
    networksetup -setmanual "Wi-Fi" $NEW_IP $NETMASK $GATEWAY
    
    sleep 2
    
    # Verify the change
    VERIFY_IP=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $2}')
    if [ "$VERIFY_IP" = "$NEW_IP" ]; then
        print_success "Đã thay đổi IP address thành: $NEW_IP"
    else
        print_error "Không thể thay đổi IP address"
        return 1
    fi
}

# Restore DHCP
restore_dhcp() {
    print_status "Khôi phục cấu hình DHCP..."
    networksetup -setdhcp "Wi-Fi"
    print_success "Đã khôi phục DHCP"
}

# Show current status
show_status() {
    echo -e "\n${BLUE}=== THÔNG TIN MẠNG HIỆN Tại ===${NC}"
    CURRENT_IP_STATUS=$(ifconfig $WIFI_INTERFACE | grep 'inet ' | awk '{print $2}')
    CURRENT_MAC_STATUS=$(ifconfig $WIFI_INTERFACE | grep ether | awk '{print $2}')
    
    echo "Interface: $WIFI_INTERFACE"
    echo "IP Address: $CURRENT_IP_STATUS"
    echo "MAC Address: $CURRENT_MAC_STATUS"
    echo "Gateway: $GATEWAY"
    echo -e "${BLUE}=================================${NC}\n"
}

# Main menu
show_menu() {
    echo -e "\n${BLUE}=== macOS Network Changer Tool ===${NC}"
    echo "1. Thay đổi cả IP và MAC address"
    echo "2. Chỉ thay đổi IP address"
    echo "3. Chỉ thay đổi MAC address"
    echo "4. Khôi phục DHCP"
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
                generate_random_ip
                generate_random_mac
                
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
                generate_random_ip
                
                print_warning "Sắp thay đổi IP: $CURRENT_IP → $NEW_IP"
                read -p "Tiếp tục? (y/N): " confirm
                
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    change_ip_address
                    show_status
                fi
                ;;
            3)
                generate_random_mac
                
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
