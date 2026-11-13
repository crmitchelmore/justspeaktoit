"""The reviewed MSIX package identity of each channel and the Windows
manifest-schema rules every identity field must satisfy."""
import hashlib
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE.parent / "windows-bundle") not in sys.path:
    sys.path.insert(0, str(HERE.parent / "windows-bundle"))
import windows_targets
from bundle_policy import APPLICATION, CLI, RESERVED_NAMES

REPOSITORY = HERE.parent.parent
IDENTITY_PATH = HERE / "package-identity.json"
BETA_IDENTITY_PATH = HERE / "package-identity-beta.json"
STORE_IDENTITY_PATH = HERE / "package-identity-store.json"
IDENTITY_PATHS = {"developer": IDENTITY_PATH, "beta": BETA_IDENTITY_PATH, "store": STORE_IDENTITY_PATH}
# The reviewed execution aliases of each channel. The native automation
# settings (WindowsAutomationSettings.cpp) choose the CLI alias by package name.
CHANNEL_IDENTITIES = {
    "developer": {"name": "com.justspeaktoit.windows.developer", "executionAlias": "JustSpeakToItDeveloper.exe",
                  "cliExecutionAlias": "JustSpeakToItDeveloperCLI.exe"},
    "beta": {"name": "com.justspeaktoit.windows", "executionAlias": "JustSpeakToIt.exe",
             "cliExecutionAlias": "JustSpeakToItCLI.exe"},
    "store": {"name": "ChrisMitchelmore.JustSpeaktoIt", "executionAlias": "JustSpeakToIt.exe",
              "cliExecutionAlias": "JustSpeakToItCLI.exe"},
}
# The Microsoft Store identity Partner Center reserved (Product identity, #1157).
# The Store refuses an upload whose manifest differs from any of these.
STORE_RESERVATION = {
    "publisher": "CN=4F44EE59-E9FC-48C5-A032-B34982E6C0CB",
    "packageFamilyName": "ChrisMitchelmore.JustSpeaktoIt_wqe2sjac9b4k8",
    "storeProductId": "9PDFKWGH31HP",
    "displayName": "Just Speak to It",
    "publisherDisplayName": "Chris Mitchelmore",
}


class PackageError(Exception):
    """A package input violates the packaging policy; nothing is written."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# --- identity rules -----------------------------------------------------------------
# Patterns are the Windows SDK 10.0.26100 AppxManifestTypes.xsd simple types
# named beside them. XSD patterns match the whole value, hence fullmatch.
_VERSION_PART = r"(0|[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])"
VERSION_PATTERN = re.compile(_VERSION_PART + r"(\." + _VERSION_PART + r"){3}")  # ST_VersionQuad
_RDN = (r"(CN|L|O|OU|E|C|S|STREET|T|G|I|SN|DC|SERIALNUMBER|Description|PostalCode|POBox|Phone|X21Address|"
        r"dnQualifier|(OID\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))+))=(([^,+=\"<>#;])+|\".*\")")
PUBLISHER_PATTERN = re.compile(_RDN + r"(, " + _RDN + r")*")  # ST_Publisher_2010_v2
PACKAGE_NAME_PATTERN = re.compile(r"[-.A-Za-z0-9]{3,50}")  # ST_PackageName
APPLICATION_ID_PATTERN = re.compile(r"([A-Za-z][A-Za-z0-9]*)(\.[A-Za-z][A-Za-z0-9]*)*")  # ST_AsciiWindowsId
EXECUTABLE_PATTERN = re.compile(r"[^\\/]+\.[Ee][Xx][Ee]")  # ST_ExecutableNoPath, no directories
# DesktopLoginItem.launchArgument: a login launch starts the app minimised.
LOGIN_LAUNCH_ARGUMENT = "--background"
FILE_NAME_FORBIDDEN = re.compile(r"[<>\":%|?*\x00-\x1f]")  # ST_FileNameCharSet
PUBLISHER_ID_ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz"
RESERVED_PACKAGE_FILES = {"appxmanifest.xml", "appxblockmap.xml", "[content_types].xml", "appxsignature.p7x"}
RESERVED_PACKAGE_DIRECTORIES = ("appxmetadata/", "microsoft.system.package.metadata/")


def _text(value, what, limit):
    # ST_NonEmptyString: no surrounding whitespace; manifests also refuse controls.
    if (not isinstance(value, str) or not value or value != value.strip() or len(value) > limit
            or re.search(r"[\x00-\x1f]", value)):
        raise PackageError("%s must be 1-%d characters without surrounding spaces or controls: %r" % (what, limit, value))
    return value


def validate_version(version):
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise PackageError("package version must be four dot-separated integers 0-65535 without leading zeros: %r"
                           % (version,))
    return version


def version_tuple(version):
    return tuple(int(part) for part in validate_version(version).split("."))


def validate_publisher(publisher):
    _text(publisher, "publisher", 8192)
    if not PUBLISHER_PATTERN.fullmatch(publisher):
        raise PackageError("publisher is not an X.500 distinguished name the manifest schema accepts: " + publisher)
    return publisher


def validate_name(name):
    if (not isinstance(name, str) or not PACKAGE_NAME_PATTERN.fullmatch(name) or name.endswith(".")
            or name.split(".")[0].lower() in RESERVED_NAMES):
        raise PackageError("package name must be 3-50 ASCII letters, digits, dots or hyphens: %r" % (name,))
    return name


def publisher_id(publisher):
    """Windows' 13-character publisher ID for a package family name.

    Base32 (Crockford alphabet, lower case) of the first 64 bits of the
    SHA-256 of the UTF-16LE publisher, padded with one zero bit.
    """
    value = int.from_bytes(hashlib.sha256(publisher.encode("utf-16-le")).digest()[:8], "big") << 1
    return "".join(PUBLISHER_ID_ALPHABET[(value >> (60 - 5 * index)) & 31] for index in range(13))


def processor_architecture(identity, architecture):
    """The manifest ProcessorArchitecture for a bundle of ``architecture`` this identity may carry."""
    value = windows_targets.target(architecture)["msixArchitecture"]
    if value not in identity["identity"]["processorArchitectures"]:
        raise PackageError("package-identity.json does not allow the %s processor architecture" % value)
    return value


def package_identity(identity, version, publisher, architecture="x64"):
    name = identity["identity"]["name"]
    family = name + "_" + publisher_id(publisher)
    architecture = processor_architecture(identity, architecture)
    return {"name": name, "publisher": publisher, "publisherId": publisher_id(publisher), "version": version,
            "architecture": architecture, "packageFamilyName": family,
            "packageFullName": "%s_%s_%s__%s" % (name, version, architecture, publisher_id(publisher)),
            "applicationId": identity["application"]["id"],
            "appUserModelId": family + "!" + identity["application"]["id"],
            "executionAlias": identity["application"]["executionAlias"],
            "cliApplicationId": identity["cli"]["id"],
            "cliAppUserModelId": family + "!" + identity["cli"]["id"],
            "cliExecutionAlias": identity["cli"]["executionAlias"],
            "displayName": identity["presentation"]["displayName"]}


def check_execution_identity(data):
    expected = CHANNEL_IDENTITIES.get(data.get("channel"))
    if expected is None:
        raise PackageError("unknown package channel: %r" % (data.get("channel"),))
    application = data["application"]
    for key in ("executable", "executionAlias"):
        value = application.get(key)
        if not isinstance(value, str) or not EXECUTABLE_PATTERN.fullmatch(value) or FILE_NAME_FORBIDDEN.search(value):
            raise PackageError(key + " must be an .exe file name without a directory")
    if data.get("cli") != {"id": "JustSpeakToItCLI", "executable": CLI,
                           "executionAlias": expected["cliExecutionAlias"]}:
        raise PackageError("cli must declare exactly JustSpeakToItCLI, speak.exe and the %s CLI execution alias"
                           % data["channel"])
    if (application["id"] != "JustSpeakToIt" or application["executable"] != APPLICATION
            or application["executionAlias"] != expected["executionAlias"]):
        raise PackageError("the existing GUI application id, executable and %s alias must not be retargeted"
                           % data["channel"])


def fixed_publisher(identity):
    """The publisher a channel always uses: the developer placeholder or the Store reservation; None for beta."""
    return identity["identity"].get("developerPublisher") or identity["identity"].get("publisher")


def _check_store_reservation(data):
    identity, presentation = data["identity"], data["presentation"]
    stated = {"publisher": identity.get("publisher"), "packageFamilyName": identity.get("packageFamilyName"),
              "storeProductId": identity.get("storeProductId"), "displayName": presentation.get("displayName"),
              "publisherDisplayName": presentation.get("publisherDisplayName")}
    if stated != STORE_RESERVATION:
        raise PackageError("the store channel must state exactly the Partner Center reservation: %r" % (stated,))
    validate_publisher(identity["publisher"])
    if identity["name"] + "_" + publisher_id(identity["publisher"]) != identity["packageFamilyName"]:
        raise PackageError("the store package family name does not match its name and publisher")


def load_identity(path=IDENTITY_PATH):
    """Load and check a channel identity: ``developer`` (package-identity.json), ``beta`` or ``store``."""
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    channel = data.get("channel")
    if data.get("schemaVersion") != 1 or channel not in CHANNEL_IDENTITIES or data.get("releaseTrain") is not None:
        raise PackageError("package identity must describe the developer or beta channel outside the release trains")
    if validate_name(data["identity"]["name"]) != CHANNEL_IDENTITIES[channel]["name"]:
        raise PackageError("the %s channel must keep its reviewed package name" % channel)
    store_keys = {"publisher", "packageFamilyName", "storeProductId"} & set(data["identity"])
    if channel == "developer":
        validate_publisher(data["identity"]["developerPublisher"])
    elif "developerPublisher" in data["identity"]:
        raise PackageError("the %s channel has no developer publisher" % channel)
    if channel == "store":
        _check_store_reservation(data)
    elif store_keys:
        raise PackageError("only the store channel states a fixed Store publisher, family or product id")
    supported = sorted(target["msixArchitecture"] for target in windows_targets.TARGETS.values())
    architectures = data["identity"].get("processorArchitectures")
    if (not isinstance(architectures, list) or not architectures or len(set(architectures)) != len(architectures)
            or not set(architectures) <= set(supported)):
        raise PackageError("processorArchitectures must list distinct supported architectures: " + ", ".join(supported))
    presentation = data["presentation"]
    for key in ("displayName", "publisherDisplayName"):
        # Windows refuses '|' in these names when it creates the firewall profile.
        if "|" in _text(presentation[key], key, 256):
            raise PackageError(key + " must not contain '|'")
    if "|" in _text(presentation["description"], "description", 2048):
        raise PackageError("description must not contain '|'")
    _text(presentation["language"], "language", 64)
    application = data["application"]
    if not APPLICATION_ID_PATTERN.fullmatch(application["id"]) or len(application["id"]) > 64:
        raise PackageError("application id is not a valid ST_AsciiWindowsId")
    check_execution_identity(data)
    startup = application.get("startupTask")
    if (not isinstance(startup, dict) or set(startup) != {"id", "parameters"}
            or not APPLICATION_ID_PATTERN.fullmatch(startup["id"]) or len(startup["id"]) > 64):
        raise PackageError("startupTask must name one task id for Launch at login")
    if startup["parameters"] != LOGIN_LAUNCH_ARGUMENT:
        raise PackageError("the startup task must pass the shared login argument " + LOGIN_LAUNCH_ARGUMENT)
    family = data["targetDeviceFamily"]
    if family["name"] != "Windows.Desktop" or version_tuple(family["minVersion"]) > version_tuple(family["maxVersionTested"]):
        raise PackageError("target device family must be Windows.Desktop with minVersion <= maxVersionTested")
    # uap10 activation attributes and desktop6 virtualisation need Windows 10 2004.
    if version_tuple(family["minVersion"]) < (10, 0, 19041, 0):
        raise PackageError("minVersion must be at least 10.0.19041.0")
    if data["capabilities"] != {"restricted": ["runFullTrust", "unvirtualizedResources"], "device": ["microphone"]}:
        raise PackageError("capabilities changed; update the manifest template and its review notes together")
    if data["fileSystem"]["writeVirtualization"] != "disabled":
        raise PackageError("file-system write virtualisation must stay disabled so uninstall retains user data")
    images = data["assets"]["images"]
    if not images or any(not path.startswith("Assets/") or not isinstance(size, int) or size < 16
                         for path, size in images.items()):
        raise PackageError("assets must be square PNG sizes under Assets/")
    return data
