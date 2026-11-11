import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "accessibility/check-linux-accessibility.py"
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

    def test_drop_down_named_by_property_only_fails(self):
        source = 'ui.mode = GTK_DROP_DOWN(gtk_drop_down_new(NULL, NULL));\n' \
                 'gtk_accessible_update_property(GTK_ACCESSIBLE(ui.mode), GTK_ACCESSIBLE_PROPERTY_LABEL, "Mode", -1);\n'
        self.assertEqual(len(self.check(source)), 1)

    def test_drop_down_named_by_helper_or_mnemonic_passes(self):
        source = 'ui.mode = GTK_DROP_DOWN(gtk_drop_down_new(NULL, NULL));\n' \
                 'jsti_accessible_set_name(GTK_WIDGET(ui.mode), "Mode");\n' \
                 'GtkWidget *size = gtk_drop_down_new_from_strings(sizes);\n' \
                 'gtk_label_set_mnemonic_widget(GTK_LABEL(label), size);\n'
        self.assertEqual(self.check(source), [])

    def test_neighbouring_drop_down_name_does_not_cover_another(self):
        source = 'GtkWidget *first = gtk_drop_down_new(NULL, NULL);\n' \
                 'GtkWidget *second = gtk_drop_down_new(NULL, NULL);\n' \
                 'jsti_accessible_set_name(second, "Second");\n'
        problems = self.check(source)
        self.assertEqual(len(problems), 1)
        self.assertIn("Widget.c:1:", problems[0])

    def test_drop_down_named_through_alias_passes(self):
        source = 'widget = gtk_drop_down_new_from_strings(items); e->fields[i] = widget;\n' \
                 'gtk_label_set_mnemonic_widget(GTK_LABEL(label), e->fields[i]);\n'
        self.assertEqual(self.check(source), [])

    def test_repository_sources_pass(self):
        root = Path(__file__).resolve().parents[2] / "Sources/CLinuxSupport"
        self.assertEqual(checker.main([str(root)]), 0)


if __name__ == "__main__":
    unittest.main()
