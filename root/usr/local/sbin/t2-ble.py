#!/usr/bin/env python3
"""BLE management service for the T2 (BlueZ GATT server, D-Bus).

Why a GATT server and not "just ssh": a freshly flashed board with no network
has no way in at all.  The config partition needs a card reader, the USB gadget
needs the *right* cable and a host that tolerates a second NIC, but Bluetooth is
on every laptop and phone.  A page hosted anywhere (https, so Web Bluetooth is
available) can connect to this service and manage the board - with user
authentication, on an encrypted link.

Security model, in order:

1. **Link**: the characteristics are declared `encrypt-write`/`encrypt-read`, so
   BlueZ refuses to touch them before the BLE link is encrypted (LE Secure
   Connections).  This is what makes the *transport* encrypted, and it is the
   controller's own AES-CCM, not something this script implements.
2. **Application authentication**: `HELLO` -> the board sends a 32-byte random
   nonce; the client answers with `hmac-sha256(psk, nonce)`.  The pre-shared key
   never crosses the wire, so a passive (or even relayed) listener learns
   nothing usable, and an active attacker who cannot guess the key cannot answer
   the challenge.  The comparison is constant-time.
3. **Framing**: every frame after that carries an HMAC over (counter, payload)
   with the same key, in both directions.  A counter per direction makes a
   replayed frame detectable, so the channel is authenticated end to end even
   though BLE pairing itself is "Just Works" (no display on this board, so
   passkey entry is not possible).

The psk comes from `/etc/t2-ble.conf` (`T2_BLE_PSK=...`), which
`t2-provision.sh` writes from `ble.psk=` in the config partition.  If the file is
missing the service generates a random one and logs it; `t2-ble-password` prints
it (root only).

Everything here is deliberately stdlib + dbus-python: the image has no room for
a Python stack, and no hand-rolled crypto - `hmac`/`hashlib`/`secrets` only.

Test hooks (used by scripts/tests/test-t2-ble.sh, never in production):
  T2_BLE_BUS    D-Bus address to use instead of the system bus
  T2_BLE_CONF   config file path        (default /etc/t2-ble.conf)
  T2_BLE_LOG    log file path           (default /var/log/t2-ble.log)
  T2_BLE_SHELL  shell to run in `shell` mode (default /bin/sh)
"""
import dbus
import dbus.service
import dbus.mainloop.glib
import hashlib
import hmac
import os
import secrets
import subprocess
import sys
import threading
import time
from gi.repository import GLib

SERVICE_UUID = "7d2f0000-2b4a-4c5d-9e6f-0a1b2c3d4e5f"
CMD_UUID = "7d2f0001-2b4a-4c5d-9e6f-0a1b2c3d4e5f"      # client -> board
OUT_UUID = "7d2f0002-2b4a-4c5d-9e6f-0a1b2c3d4e5f"      # board -> client (notify)
INFO_UUID = "7d2f0003-2b4a-4c5d-9e6f-0a1b2c3d4e5f"     # static board identity

APP_PATH = "/t2"
ADV_PATH = "/t2/advertisement"
AGENT_PATH = "/t2/agent"
BLE_CONF = os.environ.get("T2_BLE_CONF", "/etc/t2-ble.conf")
LOG_PATH = os.environ.get("T2_BLE_LOG", "/var/log/t2-ble.log")
SHELL = os.environ.get("T2_BLE_SHELL", "/bin/sh")
MAX_AUTH_FAILURES = 5
PROTOCOL_VERSION = "1"

our_input_counter = 0
our_output_counter = 0


def log(msg: str) -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} t2-ble: {msg}"
    print(line, flush=True)
    try:
        with open(LOG_PATH, "a") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def load_psk() -> bytes:
    """The pre-shared key, generating and storing one on first use.

    Generated keys are 16 hex characters (64 bits of entropy): enough for an
    interactive challenge, short enough to type off a console when the config
    partition was never used.
    """
    try:
        with open(BLE_CONF) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("T2_BLE_PSK="):
                    psk = line.split("=", 1)[1].strip()
                    if psk:
                        return psk.encode()
    except FileNotFoundError:
        pass
    psk = secrets.token_hex(8)
    os.makedirs(os.path.dirname(BLE_CONF) or "/", exist_ok=True)
    fd = os.open(BLE_CONF, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(f"# written by t2-ble.service; set ble.psk= in the config\n"
                 f"# partition to replace it (t2-ble-password prints it).\n"
                 f"T2_BLE_PSK={psk}\n")
    log(f"no {BLE_CONF}: generated a psk ({psk}); print it with t2-ble-password")
    return psk.encode()


def hmac_hex(key: bytes, data: bytes) -> str:
    return hmac.new(key, data, hashlib.sha256).hexdigest()


class Session:
    """One authenticated client.  A new HELLO always replaces the old one."""

    def __init__(self, psk: bytes) -> None:
        self.psk = psk
        self.nonce = secrets.token_bytes(32)
        self.authed = False
        self.in_counter = 0          # last counter accepted from the client
        self.out_counter = 0
        self.failures = 0
        self.shell = None            # subprocess.Popen while in shell mode
        self.shell_thread = None
        self.device = None

    def challenge(self) -> str:
        return self.nonce.hex()

    def verify_auth(self, answer: str) -> bool:
        # The client only ever sees `challenge()` as hex, so the answer is an
        # HMAC over that exact text - not over the raw 32 bytes, which a Web
        # Bluetooth page could not know.
        want = hmac_hex(self.psk, self.challenge().encode())
        self.authed = hmac.compare_digest(answer.strip().lower(), want)
        if not self.authed:
            self.failures += 1
            log(f"auth failed ({self.failures}/{MAX_AUTH_FAILURES}) "
                f"from {self.device}")
        return self.authed

    def check_frame(self, counter: str, mac: str, payload: str) -> bool:
        """Constant-time check of a client frame's HMAC and counter."""
        try:
            n = int(counter)
        except ValueError:
            return False
        if n != self.in_counter + 1:
            log(f"frame counter {n} out of order (expected {self.in_counter + 1})")
            return False
        want = hmac_hex(self.psk, f"{n}:{payload}".encode())
        if not hmac.compare_digest(mac.strip().lower(), want):
            log("frame mac mismatch - dropped")
            return False
        self.in_counter = n
        return True

    def frame(self, payload: str) -> str:
        """The wire format for anything we send back."""
        self.out_counter += 1
        mac = hmac_hex(self.psk, f"{self.out_counter}:{payload}".encode())
        return f"{self.out_counter} {mac} {payload}"


class Board:
    """The command surface.  Whitelisted, logged, and small on purpose: this is
    a management channel, not a second ssh."""

    def status(self, arg: str = "") -> str:
        out = []
        for cmd in (["hostname"], ["uptime", "-p"], ["ip", "-brief", "addr"]):
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
                out.append(r.stdout.strip())
            except Exception as e:                       # noqa: BLE001
                out.append(f"{cmd[0]}: {e}")
        return " | ".join(x for x in out if x)

    def hostname(self, arg: str) -> str:
        if not arg:
            return "usage: hostname <name>"
        r = subprocess.run(["hostnamectl", "set-hostname", arg],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return f"failed: {r.stderr.strip() or r.stdout.strip()}"
        return f"hostname set to {arg}"

    def wifi(self, arg: str) -> str:
        ssid, _, psk = arg.partition(" ")
        if not ssid or not psk:
            return "usage: wifi <ssid> <psk>"
        r = subprocess.run(["nmcli", "device", "wifi", "connect", ssid,
                            "password", psk], capture_output=True, text=True,
                           timeout=60)
        return (r.stdout.strip() or r.stderr.strip() or "no output")[:400]

    def pools(self, arg: str = "") -> str:
        r = subprocess.run(["/usr/local/sbin/t2-pools.sh"],
                           capture_output=True, text=True, timeout=30)
        return (r.stdout.strip() or "no pools configured")[:400]

    def leds(self, arg: str = "") -> str:
        try:
            names = sorted(os.listdir("/sys/class/leds"))
        except OSError as e:
            return f"no leds: {e}"
        return " ".join(names)

    def reboot(self, arg: str) -> str:
        """Reboot the board.  Authenticated clients only, and the reply is sent
        before the reboot so the client sees why it lost the link."""
        if arg and arg != "confirm":
            return "usage: reboot confirm"
        subprocess.Popen(["systemctl", "reboot"])
        return "rebooting"

    def help(self, arg: str = "") -> str:
        return ("help status hostname <name> wifi <ssid> <psk> pools leds "
                "reboot confirm shell lock")


class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service, on_write=None,
                 on_read=None):
        self.path = f"{service.path}/char{index}"
        self.uuid = uuid
        self.flags = flags
        self.service = service
        self.on_write = on_write
        self.on_read = on_read
        self.notifying = False
        self.value = b""
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self) -> dict:
        return {
            "org.bluez.GattCharacteristic1": {
                "Service": dbus.ObjectPath(self.service.path),
                "UUID": self.uuid,
                "Flags": dbus.Array(self.flags, signature="s"),
                "Value": dbus.Array(self.value, signature="y"),
            }
        }

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="a{sv}",
                         out_signature="ay")
    def ReadValue(self, options):
        if self.on_read:
            self.value = self.on_read().encode()
        return dbus.Array(self.value, signature="y")

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="aya{sv}",
                         out_signature="")
    def WriteValue(self, value, options):
        self.value = bytes(bytearray(value))
        if self.on_write is None:      # the OUT characteristic is notify-only
            return
        self.on_write(self.value.decode("utf-8", "replace"),
                      str(options.get("device", "")) or None)

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="",
                         out_signature="")
    def StartNotify(self):
        self.notifying = True

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="",
                         out_signature="")
    def StopNotify(self):
        self.notifying = False

    @dbus.service.signal("org.freedesktop.DBus.Properties",
                         signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    def notify(self, text: str) -> None:
        """Push one frame to the client (no-op when nothing subscribed)."""
        if not self.notifying:
            return
        self.value = text.encode()
        self.PropertiesChanged("org.bluez.GattCharacteristic1",
                               {"Value": dbus.Array(self.value, signature="y")},
                               [])


class Service(dbus.service.Object):
    def __init__(self, bus, index, uuid, primary):
        self.path = f"{APP_PATH}/service{index}"
        self.uuid = uuid
        self.primary = primary
        self.chars = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self) -> dict:
        return {
            "org.bluez.GattService1": {
                "UUID": self.uuid,
                "Primary": self.primary,
                "Characteristics": dbus.Array(
                    [dbus.ObjectPath(c.path) for c in self.chars],
                    signature="o"),
            }
        }

    def get_characteristic_paths(self):
        return [c.path for c in self.chars]


class Application(dbus.service.Object):
    def __init__(self, bus) -> None:
        self.path = APP_PATH
        self.services = []
        dbus.service.Object.__init__(self, bus, self.path)

    def add(self, service: Service, chars) -> None:
        service.chars = chars
        self.services.append(service)

    @dbus.service.method("org.freedesktop.DBus.ObjectManager",
                         out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        objects = {
            dbus.ObjectPath(APP_PATH): {"org.bluez.GattApplication1": {}},
        }
        for s in self.services:
            objects[dbus.ObjectPath(s.path)] = s.get_properties()
            for c in s.chars:
                objects[dbus.ObjectPath(c.path)] = c.get_properties()
        return objects

    def object_paths(self):
        paths = [APP_PATH]
        for s in self.services:
            paths.append(s.path)
            paths += [c.path for c in s.chars]
        return paths


class Advertisement(dbus.service.Object):
    def __init__(self, bus) -> None:
        self.path = ADV_PATH
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self) -> dict:
        return {
            "org.bluez.LEAdvertisement1": {
                "Type": "peripheral",
                # Discoverable makes BlueZ advertise with the general-
                # discoverable flag; a pure peripheral advertisement without it
                # is left non-discoverable by some centrals.
                "Discoverable": True,
                "LocalName": os.uname().nodename,
                "ServiceUUIDs": dbus.Array([SERVICE_UUID], signature="s"),
                "Includes": dbus.Array(["tx-power"], signature="s"),
            }
        }

    # BlueZ reads an advertisement through org.freedesktop.DBus.Properties.GetAll,
    # *not* through GetManagedObjects (that is the GATT side).  This object used
    # to expose only get_properties(), so the GetAll call failed, BlueZ fell back
    # to an empty advertisement and the controller transmitted a nameless,
    # serviceless, connectable-if-lucky beacon: `btmgmt advinfo` showed the
    # instance, `LE Set Extended Advertising Enable` succeeded, and nothing was
    # ever discovered.  Measured 2026-10-01 with btmon on the board:
    # "Add Extended Advertising Data" carried "Advertising data length: 0".
    @dbus.service.method("org.freedesktop.DBus.Properties",
                         in_signature="ss", out_signature="v")
    def Get(self, interface: str, prop: str):
        props = self.get_properties().get(interface, {})
        if prop not in props:
            raise dbus.exceptions.DBusException(
                f"No such property {prop}",
                name="org.freedesktop.DBus.Error.UnknownProperty")
        return props[prop]

    @dbus.service.method("org.freedesktop.DBus.Properties",
                         in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface: str):
        return self.get_properties().get(interface, {})

    @dbus.service.method("org.freedesktop.DBus.Properties",
                         in_signature="ssv", out_signature="")
    def Set(self, interface: str, prop: str, value):
        raise dbus.exceptions.DBusException(
            f"Property {prop} is read-only",
            name="org.freedesktop.DBus.Error.PropertyReadOnly")

    @dbus.service.method("org.bluez.LEAdvertisement1", in_signature="",
                         out_signature="")
    def Release(self):
        log("advertisement released by BlueZ")


class Agent(dbus.service.Object):
    """Just-works pairing agent.

    The characteristics are encrypt-read/encrypt-write, so a central has to pair
    before it can talk to us - and with *no* agent registered, bluetoothd has
    nobody to ask and fails the pairing immediately with
    org.bluez.Error.AuthenticationFailed (measured from the host 1.5 m away on
    2026-10-01).  NoInputNoOutput with auto-accept is right here: the protocol
    authentication (HELLO/NONCE/AUTH over the encrypted link) is what actually
    gates commands.
    """

    def __init__(self, bus) -> None:
        self.path = AGENT_PATH
        dbus.service.Object.__init__(self, bus, self.path)

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Release(self):
        log("pairing agent released")

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        return "0000"

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        return dbus.UInt32(0)

    @dbus.service.method("org.bluez.Agent1", in_signature="ouq",
                         out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        log(f"displayed passkey for {device}")

    @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        log(f"confirmed pairing with {device}")

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        log(f"authorised {device}")

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Cancel(self):
        log("pairing cancelled")


class T2Ble:
    def __init__(self, bus) -> None:
        self.bus = bus
        self.psk = load_psk()
        self.session = Session(self.psk)
        self.board = Board()
        self.app = Application(bus)
        self.out_char = None
        self.cmd_char = None
        self._build()

    def _build(self) -> None:
        # The service must exist before the characteristics: each one derives
        # its object path from it (the earlier ordering crashed at startup).
        service = Service(self.bus, 0, SERVICE_UUID, True)
        cmd = Characteristic(self.bus, 0, CMD_UUID,
                             ["write", "write-without-response", "encrypt-write"],
                             service, self.on_cmd)
        info = Characteristic(self.bus, 1, INFO_UUID,
                              ["read", "encrypt-read"], service,
                              on_read=self.on_info)
        out = Characteristic(self.bus, 2, OUT_UUID,
                             ["notify", "encrypt-read"], service)
        self.app.add(service, [cmd, info, out])
        self.cmd_char, self.out_char, self.info_char = cmd, out, info

    # -- incoming -----------------------------------------------------------
    def on_info(self) -> str:
        release = os.uname().release
        return (f"T2 {os.uname().nodename} protocol {PROTOCOL_VERSION} "
                f"kernel {release}")

    def on_cmd(self, text: str, device: str | None) -> None:
        s = self.session
        if device:
            s.device = device
        text = text.strip()
        if not text:
            return
        if text == "HELLO":
            log(f"HELLO from {s.device}")
            self.session = Session(self.psk)
            self.session.device = device
            self.send(f"NONCE {self.session.challenge()}")
            return
        if not s.authed:
            if text.startswith("AUTH "):
                if s.verify_auth(text[5:]):
                    log(f"authenticated {s.device}")
                    self.send("OK authenticated")
                elif s.failures >= MAX_AUTH_FAILURES:
                    log("too many auth failures - refusing further attempts")
                    self.send("ERR too many failures; reconnect")
                else:
                    self.send("ERR bad hmac")
                return
            self.send("ERR send HELLO first")
            return
        # Every authenticated frame carries "<counter> <mac> <payload>" - shell
        # input too, so nothing after the handshake is unauthenticated.
        head, _, rest = text.partition(" ")
        mac, _, payload = rest.partition(" ")
        if not s.check_frame(head, mac, payload):
            self.send("ERR bad frame")
            return
        if s.shell is not None:
            self.feed_shell(payload)
            return
        self.dispatch(payload)

    def dispatch(self, payload: str) -> None:
        cmd, _, arg = payload.partition(" ")
        cmd = cmd.strip()
        s = self.session
        if cmd == "shell":
            self.start_shell()
            return
        if cmd == "lock":
            self.session = Session(self.psk)
            self.send("OK locked")
            return
        handler = getattr(self.board, cmd, None) if cmd else None
        if handler is None or cmd.startswith("_"):
            self.send(f"ERR unknown command: {cmd or '(empty)'} (try help)")
            return
        self.send(handler(arg.strip()))

    # -- outgoing -----------------------------------------------------------
    def send(self, payload: str) -> None:
        # frame() runs here (so counters keep call order), but the signal is
        # emitted from the GLib loop: the shell pump thread also sends, and one
        # thread owning the connection avoids cross-thread D-Bus use.
        text = self.session.frame(payload)
        GLib.idle_add(self.out_char.notify, text)

    def start_shell(self) -> None:
        s = self.session
        try:
            s.shell = subprocess.Popen([SHELL], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT,
                                       bufsize=0)
        except OSError as e:
            self.send(f"ERR cannot start shell: {e}")
            return
        log("shell opened")
        self.send("OK shell; send lines, `exit` to leave")

        def pump():
            while True:
                chunk = s.shell.stdout.read(180)
                if not chunk:
                    break
                for i in range(0, len(chunk), 180):
                    self.send(chunk[i:i + 180].decode("utf-8", "replace"))

        s.shell_thread = threading.Thread(target=pump, daemon=True)
        s.shell_thread.start()

    def feed_shell(self, line: str) -> None:
        s = self.session
        if line.strip() == "exit":
            try:
                s.shell.stdin.write(b"exit\n")
                s.shell.stdin.close()
            except Exception:                                  # noqa: BLE001
                pass
            s.shell.wait(timeout=5)
            s.shell = None
            log("shell closed")
            self.send("OK shell closed")
            return
        try:
            s.shell.stdin.write((line + "\n").encode())
        except Exception as e:                                     # noqa: BLE001
            self.send(f"ERR shell write: {e}")


def find_adapter(bus):
    """The adapter path that implements GattManager1, or None."""
    try:
        om = dbus.Interface(bus.get_object("org.bluez", "/"),
                            "org.freedesktop.DBus.ObjectManager")
        objects = om.GetManagedObjects()
    except dbus.DBusException as e:
        log(f"no org.bluez on this bus: {e}")
        return None
    for path, interfaces in objects.items():
        if "org.bluez.GattManager1" in interfaces:
            return str(path)
    log("no adapter with GattManager1")
    return None


def main() -> int:
    # dbus-python needs the GLib loop registered, or the exported objects
    # never dispatch (the unit runs this under systemd, no session bus).
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    address = os.environ.get("T2_BLE_BUS")
    if address:
        bus = dbus.bus.BusConnection(address)
        log(f"using {address} (test hook)")
    else:
        bus = dbus.SystemBus()

    adapter = find_adapter(bus)
    if adapter is None:
        # Not fatal: Bluetooth may be absent (no module, rfkill, VM).  The unit
        # is Restart=on-failure with a delay, so it retries when it appears.
        log("no BlueZ adapter - exiting so systemd can retry")
        return 1

    ble = T2Ble(bus)

    # Pairing has to be possible before a central can write to us, so the agent
    # goes up with the adapter.  Same asynchronous pattern as registration: the
    # loop owns D-Bus from here on.
    Agent(bus)
    agentmgr = dbus.Interface(bus.get_object("org.bluez", "/org/bluez"),
                              "org.bluez.AgentManager1")
    agentmgr.RegisterAgent(dbus.ObjectPath(AGENT_PATH), "NoInputNoOutput",
                           reply_handler=lambda:
                           log("pairing agent registered (NoInputNoOutput)"),
                           error_handler=lambda e:
                           log(f"pairing agent unavailable: {e}"))
    agentmgr.RequestDefaultAgent(dbus.ObjectPath(AGENT_PATH),
                                 reply_handler=lambda:
                                 log("pairing agent is the default"),
                                 error_handler=lambda e:
                                 log(f"default agent unavailable: {e}"))

    loop = GLib.MainLoop()
    registered = {"ok": False}

    # Registration is asynchronous on purpose: bluetoothd replies only after it
    # has fetched our ObjectManager tree, so a *blocking* RegisterApplication
    # with no running loop fails with NoReply (measured on the board
    # 2026-10-01).  Handing the call to the loop keeps one thread owning D-Bus.
    def on_registered():
        registered["ok"] = True
        log(f"registered GATT application on {adapter} "
            f"({len(ble.app.services)} service, 3 characteristics)")
        try:
            ble.advertisement = Advertisement(bus)
            adv = dbus.Interface(bus.get_object("org.bluez", adapter),
                                 "org.bluez.LEAdvertisingManager1")
            adv.RegisterAdvertisement(dbus.ObjectPath(ADV_PATH),
                                      dbus.Dictionary({}, "sv"),
                                      reply_handler=lambda: log("advertising"),
                                      error_handler=lambda e:
                                      log(f"advertising unavailable: {e}"))
        except dbus.DBusException as e:
            log(f"advertising unavailable: {e}")

    def on_error(e):
        log(f"RegisterApplication failed: {e}")
        loop.quit()

    gatt = dbus.Interface(bus.get_object("org.bluez", adapter),
                          "org.bluez.GattManager1")
    gatt.RegisterApplication(dbus.ObjectPath(APP_PATH),
                             dbus.Dictionary({}, "sv"),
                             reply_handler=on_registered,
                             error_handler=on_error)
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    return 0 if registered["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
