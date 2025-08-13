#Requires -RunAsAdministrator

# Windows IP & MAC Address Changer Tool
# Thay đổi IP và MAC address trên máy Windows thật, tương tự VMware Network Editor

# Colors for output (PowerShell style)
$Red = "Red"
$Green = "Green"
$Yellow = "Yellow"
$Blue = "Blue"
$Default = "White"

function Write-Status($Message) {
    Write-Host "[THÔNG BÁO] $Message" -ForegroundColor $Blue
}

function Write-Success($Message) {
    Write-Host "[THÀNH CÔNG] $Message" -ForegroundColor $Green
}

function Write-Warning($Message) {
    Write-Host "[CẢNH BÁO] $Message" -ForegroundColor $Yellow
}

function Write-Error($Message) {
    Write-Host "[LỖI] $Message" -ForegroundColor $Red
}

# Get Wi-Fi interface
function Get-WiFiInterface {
    $script:Interface = Get-NetAdapter | Where-Object { $_.Name -like "*Wi-Fi*" -or $_.Name -like "*Wireless*" }
    if (-not $Interface) {
        Write-Error "Không tìm thấy giao diện Wi-Fi"
        exit 1
    }
    Write-Status "Giao diện Wi-Fi: $($Interface.Name)"
}

# Get current network info
function Get-NetworkInfo {
    Write-Status "Đang lấy thông tin mạng hiện tại..."
    
    $script:CurrentIP = (Get-NetIPAddress -InterfaceAlias $Interface.Name -AddressFamily IPv4).IPAddress
    $script:Netmask = (Get-NetIPAddress -InterfaceAlias $Interface.Name -AddressFamily IPv4).PrefixLength
    $script:Gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceAlias $Interface.Name).NextHop
    
    if (-not $CurrentIP -or -not $Gateway) {
        Write-Error "Không thể lấy thông tin mạng. Kiểm tra kết nối Wi-Fi"
        exit 1
    }
    
    Write-Status "IP hiện tại: $CurrentIP"
    Write-Status "Gateway: $Gateway"
    Write-Status "Netmask: $Netmask"
}

# Calculate network range
function Calculate-NetworkRange {
    # Convert CIDR to usable IP range
    $script:NetworkAddr = $CurrentIP.Split('.')[0..2] -join '.'
    $script:IPRangeStart = "$NetworkAddr.2"
    $script:IPRangeEnd = "$NetworkAddr.254"  # Giả định /24
    
    if ($Netmask -lt 24) {
        Write-Warning "Hỗ trợ hạn chế cho subnet lớn (/$Netmask). Sử dụng IP thủ công nếu cần."
        $IPRangeStart = "$NetworkAddr.1.2"
        $IPRangeEnd = "$NetworkAddr.254.254"
    }
    
    Write-Status "Dải mạng: $NetworkAddr/$Netmask"
    Write-Status "IP có thể sử dụng: $IPRangeStart - $IPRangeEnd"
}

# Generate or set manual IP
function Set-IP {
    $ipMode = Read-Host "Tạo IP ngẫu nhiên (r) hay nhập thủ công (m)? (r/m)"
    if ($ipMode -eq 'm') {
        $script:NewIP = Read-Host "Nhập IP mới (ví dụ: 192.168.1.100)"
        if (-not ($NewIP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')) {
            Write-Error "IP không hợp lệ"
            Set-IP
        }
    } else {
        $start = [int]($IPRangeStart.Split('.')[-1])
        $end = [int]($IPRangeEnd.Split('.')[-1])
        $randomOctet = Get-Random -Minimum $start -Maximum ($end + 1)
        $script:NewIP = "$($NetworkAddr).$randomOctet"
        
        while ($NewIP -eq $CurrentIP -or $NewIP -eq $Gateway) {
            $randomOctet = Get-Random -Minimum $start -Maximum ($end + 1)
            $script:NewIP = "$($NetworkAddr).$randomOctet"
        }
    }
    
    # Check for IP conflict
    $pingResult = Test-Connection -ComputerName $NewIP -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($pingResult) {
        Write-Warning "IP $NewIP đang được sử dụng. Tạo lại..."
        Set-IP
    } else {
        Write-Status "IP mới: $NewIP"
    }
}

# Generate or set manual MAC
function Set-MAC {
    $macMode = Read-Host "Tạo MAC ngẫu nhiên (r) hay nhập thủ công (m)? (r/m)"
    if ($macMode -eq 'm') {
        $script:NewMAC = Read-Host "Nhập MAC mới (ví dụ: 02:xx:xx:xx:xx:xx)"
        if (-not ($NewMAC -match '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$')) {
            Write-Error "MAC không hợp lệ"
            Set-MAC
        }
    } else {
        $script:NewMAC = "02" + (":%02X" -f (Get-Random -Minimum 0 -Maximum 256)) * 5
    }
    Write-Status "MAC mới: $NewMAC"
}

# Change MAC address
function Change-MACAddress {
    Write-Status "Đang thay đổi MAC address..."
    Write-Warning "Thay đổi MAC có thể không hoạt động nếu card mạng không hỗ trợ. Kiểm tra driver."
    
    Disable-NetAdapter -Name $Interface.Name
    Start-Sleep -Seconds 3
    
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\"
    $adapterReg = Get-ChildItem $regPath | Where-Object { (Get-ItemProperty -Path $_.PSPath).DriverDesc -eq $Interface.InterfaceDescription }
    
    if ($adapterReg) {
        Set-ItemProperty -Path $adapterReg.PSPath -Name "NetworkAddress" -Value $NewMAC.Replace(":", "")
        Enable-NetAdapter -Name $Interface.Name
        Start-Sleep -Seconds 5
        
        $currentMAC = (Get-NetAdapter -Name $Interface.Name).MacAddress
        if ($currentMAC -eq $NewMAC) {
            Write-Success "Đã thay đổi MAC thành: $NewMAC"
        } else {
            Write-Error "Thay đổi MAC thất bại. Thử dùng Technitium MAC Address Changer."
        }
    } else {
        Write-Error "Không tìm thấy registry của adapter. Thử công cụ bên thứ ba."
    }
}

# Change IP address
function Change-IPAddress {
    Write-Status "Đang thay đổi IP address..."
    
    $subnetMask = "255.255.255.0"  # Giả định /24, có thể cải tiến
    Set-NetIPAddress -InterfaceAlias $Interface.Name -IPAddress $NewIP -PrefixLength $Netmask
    Set-NetIPInterface -InterfaceAlias $Interface.Name -DefaultGateway $Gateway
    
    Start-Sleep -Seconds 3
    
    $verifyIP = (Get-NetIPAddress -InterfaceAlias $Interface.Name -AddressFamily IPv4).IPAddress
    if ($verifyIP -eq $NewIP) {
        Write-Success "Đã thay đổi IP thành: $NewIP"
    } else {
        Write-Error "Thay đổi IP thất bại"
    }
}

# Restore DHCP
function Restore-DHCP {
    Write-Status "Khôi phục cấu hình DHCP (tương tự bridged mode)..."
    Set-NetIPInterface -InterfaceAlias $Interface.Name -Dhcp Enabled
    Remove-NetIPAddress -InterfaceAlias $Interface.Name -Confirm:$false
    Remove-NetRoute -InterfaceAlias $Interface.Name -Confirm:$false
    Write-Success "Đã khôi phục DHCP"
}

# Show current status
function Show-Status {
    Write-Host "`n=== THÔNG TIN MẠNG HIỆN TẠI ===" -ForegroundColor $Blue
    $currentIP = (Get-NetIPAddress -InterfaceAlias $Interface.Name -AddressFamily IPv4).IPAddress
    $currentMAC = (Get-NetAdapter -Name $Interface.Name).MacAddress
    
    Write-Host "Giao diện: $($Interface.Name)"
    Write-Host "IP Address: $currentIP"
    Write-Host "MAC Address: $currentMAC"
    Write-Host "Gateway: $Gateway"
    Write-Host "================================" -ForegroundColor $Blue
}

# Main menu
function Show-Menu {
    Write-Host "`n=== Công Cụ Thay Đổi Mạng Windows ===" -ForegroundColor $Blue
    Write-Host "1. Thay đổi cả IP và MAC (thủ công hoặc ngẫu nhiên)"
    Write-Host "2. Chỉ thay đổi IP (static mode)"
    Write-Host "3. Chỉ thay đổi MAC"
    Write-Host "4. Khôi phục DHCP (bridged mode)"
    Write-Host "5. Hiển thị thông tin mạng hiện tại"
    Write-Host "6. Thoát"
    Write-Host "================================" -ForegroundColor $Blue
    $script:choice = Read-Host "Chọn tùy chọn (1-6)"
}

# Main function
function Main {
    Get-WiFiInterface
    while ($true) {
        Show-Menu
        switch ($choice) {
            1 {
                Get-NetworkInfo
                Calculate-NetworkRange
                Set-IP
                Set-MAC
                Write-Warning "Sắp thay đổi:"
                Write-Host "  IP: $CurrentIP → $NewIP"
                Write-Host "  MAC: $((Get-NetAdapter -Name $Interface.Name).MacAddress) → $NewMAC"
                $confirm = Read-Host "Tiếp tục? (y/N)"
                if ($confirm -eq 'y') {
                    Change-MACAddress
                    Change-IPAddress
                    Show-Status
                }
            }
            2 {
                Get-NetworkInfo
                Calculate-NetworkRange
                Set-IP
                Write-Warning "Sắp thay đổi IP: $CurrentIP → $NewIP"
                $confirm = Read-Host "Tiếp tục? (y/N)"
                if ($confirm -eq 'y') {
                    Change-IPAddress
                    Show-Status
                }
            }
            3 {
                Set-MAC
                Write-Warning "Sắp thay đổi MAC: $((Get-NetAdapter -Name $Interface.Name).MacAddress) → $NewMAC"
                $confirm = Read-Host "Tiếp tục? (y/N)"
                if ($confirm -eq 'y') {
                    Change-MACAddress
                    Show-Status
                }
            }
            4 {
                Restore-DHCP
                Show-Status
            }
            5 {
                Get-NetworkInfo
                Show-Status
            }
            6 {
                Write-Success "Tạm biệt!"
                exit 0
            }
            default {
                Write-Error "Lựa chọn không hợp lệ"
            }
        }
        Write-Host "`nNhấn Enter để tiếp tục..."
        Read-Host
    }
}

# Run main function
Main
