# Fan control (Raspberry Pi 5)

Files
- `polaris-fan` -> `/usr/local/sbin/polaris-fan` (root:root 0755). Root helper: `status | auto | set <0-255> [sec] | max [sec]`.
- `polaris-fan.sudoers` -> `/etc/sudoers.d/polaris-fan` (root:root 0440). Lets only user `polaris` run that one command.
- `server/polaris_app_api.py` adds `GET/POST /v1/fan` (+ `kernel`, `serverVersion` on `/v1/status`).

Install (on the Pi, from this directory):

    sudo install -o root -g root -m 0755 polaris-fan /usr/local/sbin/polaris-fan
    sudo visudo -c -f polaris-fan.sudoers && sudo install -o root -g root -m 0440 polaris-fan.sudoers /etc/sudoers.d/polaris-fan
    # then copy polaris_app_api.py and restart polaris-app-api

What the kernel does (6.12.47+rpt-rpi-2712, driver pwm-fan, hwmon `pwmfan`, found by name)
- `pwm1_enable` 0 = fan off (pwm1 writes ignored, pwm1 reads 0); 1 = duty taken from `pwm1`; 2 = accepted, behaves like 1
  (3 is accepted too and is meaningless). Boot default and the firmware "automatic" state is 1.
- The `step_wise` thermal governor keeps running in mode 1: a manual `pwm1` is pulled down one cooling state about every
  2 s (255 -> 175 -> 125 -> 75). So a manual value only sticks while `thermal_zone0/mode` is `disabled`.
  The only cooling device on that zone is the fan, and `temp` stays readable while disabled.
- Hence `set`/`max`: zone disabled + `pwm1_enable=1` + `pwm1`. `auto`: write `cooling_device0/cur_state` for the current
  temperature (trips 50/60/67.5/75 C -> states 1..4; levels 0/75/125/175/250), then zone `enabled`.
- Safety: a hold always arms a root systemd timer (`polaris-fan-deadman`) that runs `auto`; helper and service both
  apply: >=75 C or unreadable -> automatic, >65 C min 50 %, >50 C never below ~30 %.

Test hooks of the service (unset in production): `FAN_TEST_TEMP_FILE`, `FAN_TEST_SECONDS_PER_MINUTE`,
`FAN_TEST_COOL_SECONDS`, `FAN_TEST_TICK_SECONDS`, `FAN_TEST_REAPPLY_SECONDS`, `FAN_HELPER`.
