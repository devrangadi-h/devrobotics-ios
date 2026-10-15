// Run: mkdir -p /tmp/aboutcheck-src && cp Tools/aboutcheck.swift /tmp/aboutcheck-src/main.swift && swiftc -o /tmp/aboutcheck Sources/DevRobotics/Settings/About/ProfileAndExpiry.swift /tmp/aboutcheck-src/main.swift && /tmp/aboutcheck
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok:   \(what)") } }

// A fake CMS blob: binary junk, then the XML plist, then junk (mirrors embedded.mobileprovision).
let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ExpirationDate</key><date>2026-10-21T23:26:00Z</date>
<key>CreationDate</key><date>2026-10-14T23:26:00Z</date>
<key>TeamName</key><string>Hardik Devrangadi</string>
<key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
<key>ProvisionedDevices</key><array><string>a</string><string>b</string></array>
</dict></plist>
"""
var blob = Data([0x30, 0x82, 0x0b, 0xff, 0x06, 0x09, 0x2a])
blob.append(Data(plist.utf8))
blob.append(Data([0x00, 0xa0, 0x81, 0xfe]))
let p = ProvisioningProfile.parse(blob)
check(p?.teamName == "Hardik Devrangadi", "team name")
check(p?.teamID == "ABCDE12345", "team id")
check(p?.deviceCount == 2, "device count")
check(p?.expiration == ISO8601DateFormatter().date(from: "2026-10-21T23:26:00Z"), "expiration")
check(ProvisioningProfile.parse(Data([1, 2, 3])) == nil, "garbage -> nil")
check(ProvisioningProfile.parse(Data("<?xml broken".utf8)) == nil, "truncated -> nil")

let d = 86400.0, h = 3600.0
check(ExpiryMath.remainingText(6 * d + 4 * h + 100) == "6 days 4 h left", "6 days 4 h")
check(ExpiryMath.remainingText(1 * d + 2 * h) == "1 day 2 h left", "singular day")
check(ExpiryMath.remainingText(5 * h + 12 * 60) == "5 h 12 min left", "hours")
check(ExpiryMath.remainingText(9 * 60 + 5) == "9 min left", "minutes")
check(ExpiryMath.remainingText(-2 * d - 3 * h) == "Expired 2 days 3 h ago", "expired")
check(ExpiryMath.chipText(6 * d + 4 * h) == "Expires in 6 d", "chip days")
check(ExpiryMath.chipText(5 * h) == "Expires in 5 h", "chip hours")
check(ExpiryMath.chipText(-1) == "Expired", "chip expired")
check(ExpiryMath.level(remaining: 3 * d) == .ok, "level ok")
check(ExpiryMath.level(remaining: 47 * h) == .soon, "level soon (<48 h)")
check(ExpiryMath.level(remaining: 11 * h) == .urgent, "level urgent (<12 h)")
check(ExpiryMath.level(remaining: 0) == .expired, "level expired")
let now = Date(timeIntervalSince1970: 1_000_000)
check(ExpiryMath.reminderDate(expiry: now.addingTimeInterval(3 * d), now: now) == now.addingTimeInterval(2 * d), "reminder 1 day before")
check(ExpiryMath.reminderDate(expiry: now.addingTimeInterval(h), now: now) == nil, "no reminder in the past")
check(ExpiryMath.fraction(remaining: 3.5 * d) == 0.5, "fraction")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
