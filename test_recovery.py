from pathlib import Path
import unittest
from unittest.mock import patch
import assistant as app


class RecoveryTests(unittest.TestCase):
    def test_focus_then_escalate_only_if_still_unavailable(self):
        recovery = app.Recovery()
        with patch.object(app, 'native') as native, patch.object(app, 'log') as log, \
             patch.object(app, 'recover_with_agent', return_value=('wait','加载中')) as agent, \
             patch.object(app.time, 'monotonic', side_effect=[0,5,10,15,30]):
            for _ in range(5):
                recovery.observe_fault('课程','缩略图',Path('.'),True)
            native.assert_called_once_with('focus')
            agent.assert_called_once()
            self.assertFalse(any(c.args[0] == 'recovered' for c in log.call_args_list))
            recovery.verified()
            self.assertEqual(log.call_args.args[0],'recovered')

    def test_detect_only_uses_local_recovery(self):
        with patch.object(app, 'native') as native, patch.object(app, 'log'), \
             patch.object(app, 'recover_with_agent') as agent:
            app.Recovery().observe_fault('课程','缩略图',Path('.'),False)
            native.assert_called_once_with('focus')
            agent.assert_not_called()

    def test_agent_can_retry_but_cannot_submit(self):
        lines = [dict(text='重新加载',x=.5,y=.55),dict(text='提交',x=.5,y=.7)]
        frame = dict(id=42,lines=lines)
        for index in [0,1]:
            with self.subTest(index=index), patch.object(app,'native',return_value=frame) as native, \
                 patch.object(app,'ask_model',return_value=dict(action='click',target=index,reason='恢复')):
                action, _ = app.recover_with_agent('课程','读取异常',Path('.'))
                self.assertEqual(action, 'click' if index == 0 else 'wait')
                self.assertEqual(native.call_count, 2 if index == 0 else 1)
                if index == 0:
                    native.assert_called_with('act',42,Path('recovery.png'),.5,.55)

    def test_login_handled_locally(self):
        with patch.object(app,'native',return_value=dict(id=1,lines=[dict(text='扫码登录',x=.5,y=.4)])), \
             patch.object(app,'ask_model') as model:
            action, _ = app.recover_with_agent('课程','离开列表',Path('.'))
            self.assertEqual(action,'needs_user')
            model.assert_not_called()
