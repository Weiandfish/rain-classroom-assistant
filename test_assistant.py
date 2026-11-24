import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import assistant as app


def line(text, x, y):
    return dict(text=text, x=x, y=y)


class FlowTests(unittest.TestCase):
    def test_submission_and_receipt(self):
        pending = dict(id=1, pending=[dict(page="P20")], lines=[line("P20", .3, .2)])
        detail = dict(id=1, pending=[], lines=[line("提交", .5, .9)])
        receipt = dict(id=1, pending=[], lines=[
            line("PPT", .3, .1), line("习题", .5, .1), line("P20", .3, .2)])
        frames = iter([pending, detail, detail, receipt])
        clicks = []
        def native(mode, *args):
            if mode == "frame":
                return next(frames)
            clicks.append(args)
        def step(action, x, y):
            return dict(action=action, x=x, y=y, text="", evidence="本题已打勾")
        answers = iter([step("choose", .3, .5), step("submit", .5, .9), step("completed", 0, 0)])
        with TemporaryDirectory() as tmp, patch.object(app, "native", native), \
             patch.object(app, "next_action", side_effect=answers), patch.object(app.time, "sleep"):
            root = Path(tmp)
            journal = root/"submitted.json"
            self.assertEqual(app.answer("课程", "P20", root, set(), journal), "已核实提交")
            self.assertEqual(json.loads(journal.read_text()), ["P20"])
            self.assertEqual(len(clicks), 3)

    def test_stale_card(self):
        with patch.object(app, "native", return_value={"pending":[]}) as native:
            self.assertEqual(app.answer("课程", "P20", Path("."), set(), Path("unused")), "卡片状态已变化")
            self.assertEqual(native.call_count, 1)


if __name__ == "__main__":
    unittest.main()
