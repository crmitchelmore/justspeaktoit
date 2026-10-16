"""Execute the production terminal tour branch with fake native UI boundaries.

Run with: CC=clang python3 -m unittest scripts.tests.test_linux_comparison_tour_handoff
This tests driver ownership, not GTK rendering or screenshot contents.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def final_stage_body():
    source = (ROOT / "Sources/CLinuxSupport/LinuxWindow.c").read_text(encoding="utf-8")
    capture = source.index("static gboolean tour_capture(gpointer data) {")
    stage = source.index("if (tour->step == TOUR_VOICE_DISCOVERY)", capture)
    opening = source.index("{", stage)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[opening + 1 : end - 1]


HARNESS = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { char *directory; } Tour;
typedef void GtkWindow;
static struct { GtkWindow *window; } ui;
static int snapshots, comparisons, parent_closed, copied_directory, snapshot_result;
static char received_directory[128];
#define G_SOURCE_REMOVE 0
#define g_free free
#define g_printerr(...) fprintf(stderr, __VA_ARGS__)
static char *copy(const char *text) {
    char *result = malloc(strlen(text) + 1);
    strcpy(result, text);
    return result;
}
static int jsti_voice_discovery_save_snapshot(const char *path) {
    snapshots++;
    return snapshot_result;
}
static void gtk_window_close(GtkWindow *parent) { parent_closed++; }
static void jsti_comparison_screenshot_tour(GtkWindow *parent, const char *directory) {
    comparisons++;
    copied_directory = parent == ui.window && strcmp(directory, "frozen-e521-output") == 0;
    snprintf(received_directory, sizeof received_directory, "%s", directory);
}
static int capture_final(Tour *tour) {
    char *path = copy("frozen-e521-output/27-voice-discovery.png");
    char *file = copy("27-voice-discovery.png");
    __FINAL_STAGE__
}
int main(int argc, char **argv) {
    int parent = 0;
    ui.window = &parent;
    snapshot_result = atoi(argv[1]);
    Tour *tour = malloc(sizeof *tour);
    tour->directory = copy("frozen-e521-output");
    int result = capture_final(tour);
    printf("{\"snapshots\":%d,\"comparisons\":%d,\"parent_closed\":%d,"
           "\"copied_directory\":%d,\"result\":%d}\n",
           snapshots, comparisons, parent_closed, copied_directory, result);
    return strcmp(received_directory, "frozen-e521-output") != 0;
}
"""


class ComparisonTourHandoffTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang")
        if not compiler:
            raise RuntimeError("Set CC to a C compiler to run the native tour-driver regression.")
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        source = Path(cls.directory.name) / "tour.c"
        cls.binary = Path(cls.directory.name) / "tour"
        source.write_text(HARNESS.replace("__FINAL_STAGE__", final_stage_body()), encoding="utf-8")
        subprocess.run([compiler, "-std=c11", str(source), "-o", str(cls.binary)], check=True)

    def assert_handoff(self, snapshot_result):
        result = subprocess.run(
            [str(self.binary), str(snapshot_result)], capture_output=True, text=True
        )
        state = json.loads(result.stdout)
        self.assertEqual(state["snapshots"], 1, state)
        self.assertEqual(state["comparisons"], 1, state)
        self.assertEqual(state["parent_closed"], 0, state)
        self.assertEqual(state["copied_directory"], 1, state)
        self.assertEqual(state["result"], 0, state)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_final_voice_stage_hands_off_before_freeing_directory_or_closing_parent(self):
        self.assert_handoff(0)

    def test_failed_voice_snapshot_still_runs_comparison_stage(self):
        self.assert_handoff(-1)


if __name__ == "__main__":
    unittest.main()
