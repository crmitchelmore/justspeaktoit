"""Render AppxManifest.xml from the reviewed template and check that a
manifest states exactly the reviewed identity, activation, capabilities and
logos."""
import pathlib
import string
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

from msix_identity import (
    HERE,
    PackageError,
    check_execution_identity,
    processor_architecture,
    validate_publisher,
    validate_version,
)

TEMPLATE_PATH = HERE / "AppxManifest.xml.in"
NAMESPACES = {
    "f": "http://schemas.microsoft.com/appx/manifest/foundation/windows10",
    "uap": "http://schemas.microsoft.com/appx/manifest/uap/windows10",
    "uap3": "http://schemas.microsoft.com/appx/manifest/uap/windows10/3",
    "uap5": "http://schemas.microsoft.com/appx/manifest/uap/windows10/5",
    "uap10": "http://schemas.microsoft.com/appx/manifest/uap/windows10/10",
    "desktop": "http://schemas.microsoft.com/appx/manifest/desktop/windows10",
    "desktop6": "http://schemas.microsoft.com/appx/manifest/desktop/windows10/6",
    "rescap": "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities",
}


def render_manifest(identity, version, publisher, template_path=TEMPLATE_PATH, architecture="x64"):
    presentation, application = identity["presentation"], identity["application"]
    family = identity["targetDeviceFamily"]
    values = {
        "name": identity["identity"]["name"], "publisher": validate_publisher(publisher),
        "version": validate_version(version), "architecture": processor_architecture(identity, architecture),
        "displayName": presentation["displayName"], "publisherDisplayName": presentation["publisherDisplayName"],
        "description": presentation["description"], "language": presentation["language"],
        "fileSystemWriteVirtualization": identity["fileSystem"]["writeVirtualization"],
        "deviceFamily": family["name"], "minVersion": family["minVersion"],
        "maxVersionTested": family["maxVersionTested"], "applicationId": application["id"],
        "executable": application["executable"], "executionAlias": application["executionAlias"],
        "cliApplicationId": identity["cli"]["id"],
        "cliExecutable": identity["cli"]["executable"], "cliExecutionAlias": identity["cli"]["executionAlias"],
        "startupTaskId": application["startupTask"]["id"],
        "startupTaskParameters": application["startupTask"]["parameters"],
    }
    escaped = {key: escape(value, {'"': "&quot;"}) for key, value in values.items()}
    data = string.Template(pathlib.Path(template_path).read_text(encoding="utf-8")).substitute(escaped).encode("utf-8")
    check_manifest(data, identity, version, publisher, architecture)
    return data


def check_manifest(data, identity, version, publisher, architecture="x64"):
    """Check the rendered manifest states exactly the reviewed identity and policy."""
    check_execution_identity(identity)
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise PackageError("manifest is not well-formed XML: %s" % error) from error
    ns = NAMESPACES
    if root.tag != "{%s}Package" % ns["f"]:
        raise PackageError("manifest root must be the foundation Package element")
    if "desktop6" in (root.get("IgnorableNamespaces") or "").split():
        raise PackageError("desktop6 must not be ignorable: an OS that cannot honour it must refuse the package")
    found = root.find("f:Identity", ns)
    expected = {"Name": identity["identity"]["name"], "Publisher": publisher, "Version": version,
                "ProcessorArchitecture": processor_architecture(identity, architecture)}
    if found is None or {key: found.get(key) for key in expected} != expected:
        raise PackageError("manifest identity differs from the requested identity")
    if root.findtext("f:Properties/desktop6:FileSystemWriteVirtualization", namespaces=ns) != "disabled":
        raise PackageError("manifest must disable file-system write virtualisation")
    applications = root.findall("f:Applications/f:Application", ns)
    application = identity["application"]
    if len(applications) != 2:
        raise PackageError("manifest must declare exactly the reviewed GUI and hidden CLI applications")
    for index, (element, expected_application) in enumerate(zip(applications, (application, identity["cli"]))):
        expected_attributes = {
            "Id": expected_application["id"], "Executable": expected_application["executable"],
            "{%s}TrustLevel" % ns["uap10"]: "mediumIL",
            "{%s}RuntimeBehavior" % ns["uap10"]: "packagedClassicApp",
        }
        if index == 1:
            # The CLI alias extension declares uap10:Subsystem="console"; the schema requires its own
            # Application to also declare uap10:SupportsMultipleInstances="true". The GUI Application has
            # no console alias and must not carry this attribute.
            expected_attributes["{%s}SupportsMultipleInstances" % ns["uap10"]] = "true"
        if element.attrib != expected_attributes:
            raise PackageError("manifest application identity and activation must match the reviewed GUI and CLI")
        visual = element.find("uap:VisualElements", ns)
        app_extensions = element.find("f:Extensions", ns)
        if visual is None or app_extensions is None or list(element) != [visual, app_extensions]:
            raise PackageError("each application must contain exactly its visual elements and reviewed extensions")
        expected_visual = {
            "DisplayName": identity["presentation"]["displayName"],
            "Description": identity["presentation"]["description"], "BackgroundColor": "transparent",
            "Square150x150Logo": "Assets\\Square150x150Logo.png",
            "Square44x44Logo": "Assets\\Square44x44Logo.png",
        }
        if index == 1:
            expected_visual["AppListEntry"] = "none"
            categories = ["windows.appExecutionAlias"]
        else:
            categories = ["windows.appExecutionAlias", "windows.startupTask"]
        if visual.attrib != expected_visual or list(visual):
            raise PackageError("manifest must keep canonical GUI visuals and a hidden CLI with the same icons")
        if ([child.get("Category") for child in app_extensions] != categories
                or app_extensions.attrib):
            raise PackageError("each application must declare exactly one alias extension and only the GUI startup")
    extensions = [element for element in root.iter() if element.get("Category") == "windows.appExecutionAlias"]
    expected_aliases = [
        ("uap3", application["executable"], "desktop", application["executionAlias"], {}),
        ("uap5", identity["cli"]["executable"], "uap5", identity["cli"]["executionAlias"],
         {"{%s}Subsystem" % ns["uap10"]: "console"}),
    ]
    if len(extensions) != len(expected_aliases):
        raise PackageError("manifest must declare exactly the reviewed GUI and CLI alias extensions")
    for index, (extension, (prefix, executable, alias_prefix, alias, attributes)) in enumerate(
            zip(extensions, expected_aliases)):
        expected_extension = {
            "Category": "windows.appExecutionAlias", "Executable": executable,
            "{%s}RuntimeBehavior" % ns["uap10"]: "packagedClassicApp",
            "{%s}TrustLevel" % ns["uap10"]: "mediumIL",
        }
        children = list(extension)
        if (extension not in list(applications[index].find("f:Extensions", ns))
                or extension.tag != "{%s}Extension" % ns[prefix] or extension.attrib != expected_extension
                or len(children) != 1 or children[0].tag != "{%s}AppExecutionAlias" % ns[prefix]
                or children[0].attrib != attributes or len(list(children[0])) != 1
                or children[0][0].tag != "{%s}ExecutionAlias" % ns[alias_prefix]
                or children[0][0].attrib != {"Alias": alias} or list(children[0][0])):
            raise PackageError("manifest execution alias must match its reviewed executable and console attributes")
    aliases = [element for element in root.iter() if element.tag.rsplit("}", 1)[-1] == "ExecutionAlias"]
    if len(aliases) != 2:
        raise PackageError("manifest must contain exactly the reviewed execution aliases")
    tasks = [element for element in root.iter("{%s}Extension" % ns["desktop"])
             if element.get("Category") == "windows.startupTask"]
    startup = application["startupTask"]
    declared = [(element.get("Executable"), element.get("EntryPoint"), element.get("{%s}Parameters" % ns["uap10"]),
                 [(task.get("TaskId"), task.get("Enabled")) for task in element.findall("desktop:StartupTask", ns)])
                for element in tasks]
    if declared != [(application["executable"], "Windows.FullTrustApplication", startup["parameters"],
                     [(startup["id"], "false")])]:
        raise PackageError("manifest must declare exactly the reviewed startup task, off until the user turns it on")
    capabilities = root.find("f:Capabilities", ns)
    names = [(element.tag, element.get("Name")) for element in capabilities]
    restricted = [name for tag, name in names if tag == "{%s}Capability" % ns["rescap"]]
    device = [name for tag, name in names if tag == "{%s}DeviceCapability" % ns["f"]]
    if (restricted != identity["capabilities"]["restricted"] or device != identity["capabilities"]["device"]
            or len(names) != len(restricted) + len(device)):
        raise PackageError("manifest capabilities differ from package-identity.json")
    # The schema sequence puts every Capability before any DeviceCapability.
    if names[:len(restricted)] != [("{%s}Capability" % ns["rescap"], name) for name in restricted]:
        raise PackageError("restricted capabilities must precede device capabilities")
    logos = {root.findtext("f:Properties/f:Logo", namespaces=ns)}
    visual = applications[0].find("uap:VisualElements", ns)
    logos |= {visual.get("Square150x150Logo"), visual.get("Square44x44Logo")}
    # MRT resolves qualifier siblings automatically; only the unqualified
    # roots belong in VisualElements. Every generated variant must have a root.
    declared = {path.split(".", 1)[0] + ".png" for path in identity["assets"]["images"]}
    if not declared.issubset(identity["assets"]["images"]):
        raise PackageError("qualified logo families must include their generated unqualified assets")
    declared = {path.replace("/", "\\") for path in declared}
    if logos != declared:
        raise PackageError("manifest logos differ from the generated assets")
    return root
