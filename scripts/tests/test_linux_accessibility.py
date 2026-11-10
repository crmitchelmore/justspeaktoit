import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check-linux-accessibility.py"
spec = importlib.util.spec_from_file_location("check_linux_accessibility", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class LinuxAccessibilityCheckTests(unittest.TestCase):
    def check(self, source: str) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Widget.c"
            path.write_text(source, encoding="utf-8")
            return checker.violations(path)

    def test_unlabelled_icon_button_fails(self):
        source = 'ui.add = GTK_BUTTON(gtk_button_new_from_icon_name("list-add-symbolic"));\n' \
                 'gtk_widget_set_tooltip_text(GTK_WIDGET(ui.add), "Add");\n'
        self.assertEqual(len(self.check(source)), 1)

    def test_labelled_icon_button_passes(self):
        source = 'GtkWidget *add = gtk_button_new_from_icon_name("list-add-symbolic");\n' \
                 'gtk_accessible_update_property(GTK_ACCESSIBLE(add), GTK_ACCESSIBLE_PROPERTY_LABEL, "Add", -1);\n'
        self.assertEqual(self.check(source), [])

    def test_icon_assigned_later_needs_label(self):
        self.assertEqual(len(self.check('gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu), "open-menu");\n')), 1)

    def test_repository_sources_pass(self):
        root = Path(__file__).resolve().parents[2] / "Sources/CLinuxSupport"
        self.assertEqual(checker.main([str(root)]), 0)


if __name__ == "__main__":
    unittest.main()
