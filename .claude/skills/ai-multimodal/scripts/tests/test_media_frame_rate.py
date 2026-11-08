"""ffprobe info parsing in media_optimizer; needs neither Pillow nor ffmpeg."""

import json
import sys
from pathlib import Path
from unittest.mock import Mock, patch

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import media_optimizer as mo


class TestFrameRate:
    """ffprobe frame rates are parsed as fractions, never evaluated."""

    @pytest.mark.parametrize("raw,expected", [
        ("30000/1001", 30000 / 1001), ("25/1", 25.0), ("0/0", 0.0), ("junk", 0.0), (None, 0.0),
    ])
    def test_parse_frame_rate(self, raw, expected):
        assert mo._parse_frame_rate(raw) == pytest.approx(expected)

    @patch('media_optimizer.check_ffmpeg')
    @patch('subprocess.run')
    def test_zero_frame_rate_keeps_the_rest_of_the_info(self, mock_run, mock_check):
        mock_check.return_value = True
        mock_run.return_value = Mock(stdout=json.dumps({
            'format': {'size': '10', 'duration': '2.0', 'bit_rate': '5'},
            'streams': [{'codec_type': 'video', 'width': 640, 'height': 480, 'r_frame_rate': '0/0'}],
        }))
        info = mo.get_media_info('clip.mp4')
        assert info['width'] == 640 and info['fps'] == 0.0

    @patch('media_optimizer.check_ffmpeg')
    @patch('subprocess.run')
    def test_path_starting_with_dash_is_not_an_ffprobe_option(self, mock_run, mock_check):
        mock_check.return_value = True
        mock_run.return_value = Mock(stdout=json.dumps({'format': {}, 'streams': []}))
        mo.get_media_info('-evil.mp4')
        cmd = mock_run.call_args[0][0]
        assert cmd[-2:] == ['-i', '-evil.mp4']
