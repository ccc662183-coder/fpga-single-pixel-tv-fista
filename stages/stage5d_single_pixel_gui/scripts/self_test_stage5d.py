#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""One-command offline self-test, no COM port needed."""
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT))
from tests.test_stage5d import run
if __name__=='__main__':run()
