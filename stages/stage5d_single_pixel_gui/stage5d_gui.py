#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stage-5D | AX7020 FPGA single-pixel TV-FISTA research workstation.

This GUI is only a host/controller. It NEVER runs the TV-FISTA reconstruction
algorithm in place of the FPGA. Offline software golden images are explicitly
labeled as references, never as board measurements.
"""
from __future__ import annotations
import csv
import datetime as dt
import json
import re
import struct
import sys
import time
from pathlib import Path
from typing import Any
import numpy as np

try:
    from PySide6.QtCore import Qt, QThread, Signal
    from PySide6.QtGui import QFont, QImage, QPixmap
    from PySide6.QtWidgets import (
        QApplication, QMainWindow, QWidget, QHBoxLayout, QVBoxLayout,
        QFrame, QScrollArea, QLabel, QPushButton, QComboBox, QLineEdit,
        QProgressBar, QFileDialog, QPlainTextEdit, QTabWidget, QMessageBox,
        QCheckBox, QGridLayout, QSizePolicy)
except ImportError:
    print('未安装 PySide6。请在 PowerShell 执行：python -m pip install -r requirements.txt')
    raise SystemExit(1)

from scripts.image_pipeline import (
    DATA, MASK, MASK_SHA256, KNOWN, Q11_ONE,
    builtin_dataset, user_image_dataset, external_measurement_dataset,
    Dataset, pixels_q11_to_u8, save_grayscale, write_mem, psnr_q11,
    signed_measurements)
from scripts.board_session import run_board_session, UserCancelled
from scripts.stage5b_reconstruct import query, STATUS, STATUS_RESP

ROOT=Path(__file__).resolve().parent
STYLE='''
QWidget {background:#f5f7fa;color:#172633;font-family:"Microsoft YaHei","Microsoft JhengHei",sans-serif;font-size:10pt;}
QMainWindow {background:#f5f7fa;}
QFrame#topBar {background:white;border-bottom:1px solid #e0e6ec;}
QFrame#panel, QFrame#imageCard, QFrame#metric, QFrame#metadata {background:white;border:1px solid #e2e8ee;border-radius:10px;}
QFrame#imageCard QLabel,QFrame#metric QLabel,QFrame#metadata QLabel {background:transparent;border:none;}
QLabel#header {font-size:20pt;font-weight:700;color:#12283b;}
QLabel#eyebrow {font-size:9pt;color:#547083;}
QLabel#subHeader {font-size:11pt;font-weight:700;color:#102f40;}
QLabel#field {font-size:9pt;font-weight:600;color:#4c6575;}
QLabel#value {font-size:18pt;font-weight:700;color:#133a4d;}
QLabel#hint {font-size:9pt;color:#607789;}
QLabel#imageLabel {color:#70828e;background:#f8fafb;border:1px dashed #cfdae3;border-radius:6px;}
QPushButton {background:white;color:#173344;border:1px solid #cbd7df;padding:8px 10px;border-radius:7px;font-weight:600;}
QPushButton:hover {background:#eaf3f7;border-color:#94b5c4;}
QPushButton:disabled {color:#a9b6c0;background:#f2f5f7;border-color:#e5eaef;}
QPushButton#primary {background:#14617c;color:white;border:1px solid #14617c;font-weight:700;}
QPushButton#primary:hover {background:#0b4e67;}
QPushButton#danger {color:#a33d3d;border-color:#dfb9b9;}
QLineEdit,QComboBox {background:white;color:#172633;border:1px solid #cbd7df;padding:7px;border-radius:6px;min-height:20px;}
QLineEdit:focus,QComboBox:focus {border:1px solid #15708c;}
QPlainTextEdit {background:#0f2532;color:#e6f1f5;font-family:Consolas,"Microsoft YaHei",monospace;font-size:9pt;border:0;border-radius:7px;padding:9px;}
QProgressBar {background:#e9f0f3;border-radius:6px;min-height:13px;text-align:center;color:#173344;}
QProgressBar::chunk {background:#1687a2;border-radius:6px;}
QTabWidget::pane {border:0;background:#f5f7fa;}
QTabBar::tab {background:#e9eff3;padding:10px 19px;color:#3f5b6c;border:1px solid #dbe4eb;}
QTabBar::tab:selected {background:white;color:#0e607a;border-bottom:2px solid #0e607a;}
QCheckBox {spacing:7px;}
'''


def label(text:str,style:str='',wrap:bool=False)->QLabel:
    obj=QLabel(text)
    if style:obj.setObjectName(style)
    obj.setWordWrap(wrap)
    return obj


def vertical(gap:int=9)->QVBoxLayout:
    l=QVBoxLayout();l.setContentsMargins(0,0,0,0);l.setSpacing(gap);return l


def horizontal(gap:int=9)->QHBoxLayout:
    l=QHBoxLayout();l.setContentsMargins(0,0,0,0);l.setSpacing(gap);return l


class Worker(QThread):
    progress_changed=Signal(str,int)
    completed=Signal(object)
    failed=Signal(str)
    stopped=Signal(str)
    def __init__(self,mode:str,dataset:Dataset|None,port:str,baud:int=1000000,parent=None):
        super().__init__(parent)
        self.mode=mode;self.dataset=dataset;self.port=port;self.baud=baud
        self._stop=False
    def stop(self):self._stop=True
    def run(self):
        try:
            import serial
            self.progress_changed.emit(f'打开 {self.port}，{self.baud:,} bps，8N1',1)
            with serial.Serial(self.port,self.baud,bytesize=8,parity='N',stopbits=1,
                               timeout=.05,write_timeout=4.0) as ser:
                time.sleep(.2)
                ser.reset_input_buffer()
                if self._stop:raise UserCancelled('已取消')
                if self.mode=='ping':
                    body=query(ser,STATUS,0x2301,b'',STATUS_RESP,timeout=4.0)
                    baud,=struct.unpack('<I',body)
                    if baud!=self.baud:raise RuntimeError(f'硬件返回波特率 {baud}，预期 {self.baud}')
                    self.progress_changed.emit('真实 AX7020 状态查询通过',100)
                    self.completed.emit({'ping':True,'baud':baud});return
                if self.dataset is None:raise ValueError('尚未载入测量数据')
                result=run_board_session(ser,self.dataset,self.baud,compute_timeout=35,
                                         progress=lambda m,p:self.progress_changed.emit(m,p),
                                         cancelled=lambda:self._stop)
            self.completed.emit(result)
        except UserCancelled as exc:
            self.stopped.emit(str(exc))
        except Exception as exc:
            self.failed.emit(f'{type(exc).__name__}: {exc}')


class ImageCard(QFrame):
    def __init__(self,title:str,desc:str):
        super().__init__();self.setObjectName('imageCard')
        layout=QVBoxLayout(self);layout.setContentsMargins(15,13,15,13);layout.setSpacing(7)
        self.title=label(title,'subHeader');layout.addWidget(self.title)
        self.desc=label(desc,'hint',True);layout.addWidget(self.desc)
        self.image=label('暂无数据','imageLabel');self.image.setAlignment(Qt.AlignCenter)
        self.image.setFixedSize(256,256)
        self.image.setSizePolicy(QSizePolicy.Fixed,QSizePolicy.Fixed)
        layout.addWidget(self.image,alignment=Qt.AlignHCenter)
        self.footer=label('64 × 64 灰度','hint');self.footer.setAlignment(Qt.AlignRight)
        layout.addWidget(self.footer)
    def set_data(self,grayscale:np.ndarray|None,empty_text:str='暂无数据'):
        if grayscale is None:
            self.image.setPixmap(QPixmap());self.image.setText(empty_text);return
        a=np.ascontiguousarray(np.asarray(grayscale,dtype=np.uint8).reshape(64,64))
        qimg=QImage(a.data,64,64,64,QImage.Format_Grayscale8).copy()
        pix=QPixmap.fromImage(qimg).scaled(256,256,Qt.KeepAspectRatio,Qt.FastTransformation)
        self.image.setText('');self.image.setPixmap(pix)


class Metric(QFrame):
    def __init__(self,title:str,default:str='—'):
        super().__init__();self.setObjectName('metric')
        layout=QVBoxLayout(self);layout.setContentsMargins(13,10,13,10);layout.setSpacing(5)
        self.name=label(title,'hint');self.value=label(default,'value')
        self.value.setTextInteractionFlags(Qt.TextSelectableByMouse)
        layout.addWidget(self.name);layout.addWidget(self.value)
    def update_value(self,value:str):self.value.setText(str(value))


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('Stage-5D | AX7020 单像素成像 · TV-FISTA')
        self.resize(1370,940);self.setMinimumSize(1120,790)
        self.dataset:Dataset|None=None
        self.result:dict[str,Any]|None=None
        self.worker:Worker|None=None
        self.last_export:Path|None=None
        self._make_ui()
        self._list_ports()
        self._load_dataset()

    def _make_ui(self):
        container=QWidget();self.setCentralWidget(container)
        outer=vertical(0);container.setLayout(outer)
        top=QFrame();top.setObjectName('topBar');bar=horizontal(12);bar.setContentsMargins(23,16,23,16)
        tt=vertical(4);tt.addWidget(label('FPGA 单像素成像重建系统','header'))
        tt.addWidget(label('Stage-5D  |  AX7020 · 64×64 · Hadamard 25% · TV-FISTA 40×35','eyebrow'))
        bar.addLayout(tt,1)
        self.state_badge=label('等待连接');self.state_badge.setStyleSheet('color:#19637b;background:#e7f3f7;border-radius:13px;padding:7px 15px;font-weight:700;')
        bar.addWidget(self.state_badge,alignment=Qt.AlignVCenter)
        top.setLayout(bar);outer.addWidget(top)

        workspace=horizontal(16);workspace.setContentsMargins(18,15,18,12)
        outer.addLayout(workspace,1)
        self.leftscroll=QScrollArea();self.leftscroll.setFrameShape(QFrame.NoFrame)
        self.leftscroll.setWidgetResizable(True);self.leftscroll.setFixedWidth(353)
        left=QWidget();ll=vertical(12);ll.setContentsMargins(0,0,5,0)
        left.setLayout(ll)
        self.leftscroll.setWidget(left);workspace.addWidget(self.leftscroll)

        sourcepanel=self._panel('01  数据来源')
        sl=sourcepanel.layout()
        self.source_type=QComboBox();self.source_type.addItems(['内置标准图像','选择本地图片（生成测量）','导入外部测量向量'])
        sl.addWidget(self._field('数据模式'));sl.addWidget(self.source_type)
        self.preset=QComboBox();self.preset.addItems(['cat64','moon','rocket','text'])
        sl.addWidget(self._field('标准测试图像'));sl.addWidget(self.preset)
        self.path_box=QLineEdit();self.path_box.setPlaceholderText('请选择图像文件或测量文件')
        self.path_box.setReadOnly(True)
        frow=horizontal(6);frow.addWidget(self.path_box,1)
        self.browse=QPushButton('浏览…');frow.addWidget(self.browse)
        self.path_row=QWidget();self.path_row.setLayout(frow);sl.addWidget(self.path_row)
        self.exturl=QLineEdit();self.exturl.setPlaceholderText('论文 DOI / Zenodo / 数据集 URL（建议填写）')
        self.acquisition=QComboBox();self.acquisition.addItems(['未核验来源','第三方真实光学测量（待独立核验）','第三方模拟测量','其他研究来源'])
        self.reference_path=QLineEdit();self.reference_path.setReadOnly(True);self.reference_path.setPlaceholderText('可选：对应的参考图像')
        self.reference_browse=QPushButton('选参考')
        reference_row=horizontal(6);reference_row.addWidget(self.reference_path,1);reference_row.addWidget(self.reference_browse)
        self.reference_box=QWidget();self.reference_box.setLayout(reference_row)
        self.confirm=QCheckBox('我已确认数据与本机固定 Hadamard 算子、掩码、Q11 格式兼容')
        self.external_fields=[self.exturl,self.acquisition,self.reference_box,self.confirm]
        for e in self.external_fields:sl.addWidget(e)
        self.loadbtn=QPushButton('载入 / 生成测量数据');self.loadbtn.setObjectName('primary');sl.addWidget(self.loadbtn)
        self.source_note=label('载入后显示原图、直接反投影与黄金参考（如有）。','hint',True)
        sl.addWidget(self.source_note)
        ll.addWidget(sourcepanel)

        connection=self._panel('02  开发板连接')
        cl=connection.layout()
        cl.addWidget(self._field('串口端口'))
        prow=horizontal(7)
        self.port=QComboBox();self.port.setEditable(True);self.port.setMinimumWidth(145)
        prow.addWidget(self.port,1)
        self.refresh=QPushButton('刷新');prow.addWidget(self.refresh)
        cl.addLayout(prow)
        cl.addWidget(self._field('通信参数'))
        cl.addWidget(label('1,000,000 bps · 8N1 · 50 MHz PL · 3.3 V TTL','hint'))
        pingrow=horizontal(7)
        self.ping=QPushButton('测试板级连接');pingrow.addWidget(self.ping)
        self.runbtn=QPushButton('运行 40 轮 FPGA 重建');self.runbtn.setObjectName('primary');pingrow.addWidget(self.runbtn,1)
        cl.addLayout(pingrow)
        cl.addWidget(label('连接 J10 的 3.3 V TTL UART；运行前关闭 UART Studio。','hint',True))
        ll.addWidget(connection)

        progress=self._panel('03  任务状态')
        pl=progress.layout()
        self.phase=label('待机：尚未执行 FPGA 计算','hint',True);pl.addWidget(self.phase)
        self.progress=QProgressBar();self.progress.setRange(0,100);self.progress.setValue(0)
        pl.addWidget(self.progress)
        brow=horizontal(7)
        self.cancelbtn=QPushButton('取消任务');self.cancelbtn.setObjectName('danger');self.cancelbtn.setEnabled(False)
        self.exportbtn=QPushButton('导出实验记录');self.exportbtn.setEnabled(False)
        brow.addWidget(self.cancelbtn);brow.addWidget(self.exportbtn,1)
        pl.addLayout(brow)
        self.summary=label('输出含 JSON、PNG、Q11 原始向量、测量值与 SHA256 信息。','hint',True)
        pl.addWidget(self.summary)
        ll.addWidget(progress)

        infop=self._panel('实验标记')
        il=infop.layout()
        il.addWidget(label('软件参考 ≠ FPGA 实测','subHeader'))
        il.addWidget(label('内置四图具有冻结的 40 轮定点黄金数据；外部图像不自动具有黄金重建结果。第三方数据真实性由来源证据决定。','hint',True))
        ll.addWidget(infop)
        ll.addStretch(1)

        right=QWidget();rl=vertical(12);right.setLayout(rl);workspace.addWidget(right,1)
        cards=QGridLayout();cards.setHorizontalSpacing(10);cards.setVerticalSpacing(10)
        self.original=ImageCard('输入 / 参考图像','真实原图或第三方参考图像')
        self.direct=ImageCard('直接反投影','零填充 Hadamard 系数后的逆变换')
        self.board=ImageCard('FPGA 实际重建','仅在 AX7020 实际完成计算后显示')
        self.golden=ImageCard('冻结的软件黄金参考','仅内置四图具有 40 轮定点黄金输出')
        for i,c in enumerate([self.original,self.direct,self.board,self.golden]):
            cards.addWidget(c,i//2,i%2)
        cards.setColumnStretch(0,1);cards.setColumnStretch(1,1)
        images=QWidget();images.setLayout(cards)

        self.tabs=QTabWidget();rl.addWidget(self.tabs,1)
        visuals=QScrollArea();visuals.setWidgetResizable(True);visuals.setFrameShape(QFrame.NoFrame)
        visuals.setWidget(images);self.tabs.addTab(visuals,'图像对比')

        data_tab=QWidget();dl=vertical(14);dl.setContentsMargins(5,14,8,5);data_tab.setLayout(dl)
        p=self._panel('固定硬件计算配置');p.layout().addWidget(label(
            '64×64 灰度图  |  4096 像素  |  1024 个自然 Hadamard 系数  |  W=H4096/64  |  signed Q5.11 / S32.F11',
            'hint',True));dl.addWidget(p)
        self.metadata=QPlainTextEdit();self.metadata.setReadOnly(True);dl.addWidget(self.metadata,1)
        self.tabs.addTab(data_tab,'数据与协议')
        log_tab=QWidget();log_l=vertical(12);log_tab.setLayout(log_l)
        self.log=QPlainTextEdit();self.log.setReadOnly(True);log_l.addWidget(self.log)
        self.tabs.addTab(log_tab,'运行日志')

        footer=self._panel('硬件实测指标')
        metrics=QGridLayout();metrics.setHorizontalSpacing(9);metrics.setVerticalSpacing(9)
        self.metrics={}
        for j,(key,desc) in enumerate([
            ('match','黄金像素匹配'),('psnr','PSNR（相对原图）'),('core','PL 核心时间'),
            ('cycles','PL 计算周期'),('link','数据装载 / 回读'),('total','端到端时间')]):
            card=Metric(desc)
            self.metrics[key]=card
            metrics.addWidget(card,j//3,j%3)
        footer.layout().addLayout(metrics);rl.addWidget(footer)

        self.source_type.currentIndexChanged.connect(self._mode_changed)
        self.preset.currentIndexChanged.connect(self._invalidate)
        self.browse.clicked.connect(self._browse)
        self.reference_browse.clicked.connect(self._browse_reference)
        self.confirm.stateChanged.connect(self._invalidate)
        self.exturl.editingFinished.connect(self._invalidate)
        self.acquisition.currentIndexChanged.connect(self._invalidate)
        self.loadbtn.clicked.connect(self._load_dataset)
        self.refresh.clicked.connect(self._list_ports)
        self.ping.clicked.connect(lambda:self._start('ping'))
        self.runbtn.clicked.connect(lambda:self._start('run'))
        self.cancelbtn.clicked.connect(self._cancel)
        self.exportbtn.clicked.connect(self._choose_export)
        self._mode_changed()

    def _panel(self,header:str)->QFrame:
        p=QFrame();p.setObjectName('panel')
        l=vertical(10);l.setContentsMargins(15,13,15,14);p.setLayout(l)
        l.addWidget(label(header,'subHeader'))
        return p
    def _field(self,text:str)->QLabel:return label(text,'field')
    def _append(self,text:str):
        now=dt.datetime.now().strftime('%H:%M:%S')
        self.log.appendPlainText(f'[{now}] {text}')
    def _set_state(self,text:str,ok:bool=False):
        self.state_badge.setText(text)
        bg='#e5f5ed' if ok else '#e7f3f7'
        fg='#22704d' if ok else '#19637b'
        self.state_badge.setStyleSheet(f'color:{fg};background:{bg};border-radius:13px;padding:7px 15px;font-weight:700;')
    def _invalidate(self,*_):
        self.dataset=None;self.result=None;self.exportbtn.setEnabled(False)
        self.board.set_data(None,'尚未运行 FPGA');self.golden.set_data(None,'无黄金数据')
        for m in self.metrics.values():m.update_value('—')
        self.progress.setValue(0)
        self._set_state('未载入数据')
    def _mode_changed(self,*_):
        idx=self.source_type.currentIndex()
        self.preset.setVisible(idx==0)
        self.path_row.setVisible(idx!=0)
        for e in self.external_fields:e.setVisible(idx==2)
        self._invalidate()
    def _browse(self):
        if self.source_type.currentIndex()==1:
            fname,_=QFileDialog.getOpenFileName(self,'打开待重建图像','',
                '图像 (*.png *.jpg *.jpeg *.bmp *.tif *.tiff);;全部文件 (*)')
        else:
            fname,_=QFileDialog.getOpenFileName(self,'导入外部 1024 点测量向量','',
                '测量数据 (*.mem *.hex *.csv *.txt *.npy *.npz);;全部文件 (*)')
        if fname:self.path_box.setText(fname);self._invalidate()
    def _browse_reference(self):
        fname,_=QFileDialog.getOpenFileName(self,'选择对应的第三方参考图像','',
               '图像 (*.png *.jpg *.jpeg *.bmp *.tif *.tiff);;全部文件 (*)')
        if fname:self.reference_path.setText(fname);self._invalidate()
    def _load_dataset(self):
        if self.worker and self.worker.isRunning():return
        try:
            mode=self.source_type.currentIndex()
            if mode==0:ds=builtin_dataset(self.preset.currentText())
            elif mode==1:
                if not self.path_box.text():raise ValueError('请先选择本地图像')
                ds=user_image_dataset(self.path_box.text())
            else:
                if not self.path_box.text():raise ValueError('请先选择外部测量文件')
                ds=external_measurement_dataset(
                    self.path_box.text(),
                    reference_path=self.reference_path.text().strip() or None,
                    source_url=self.exturl.text(),
                    acquisition_type=self.acquisition.currentText(),
                    operator_confirmed=self.confirm.isChecked())
            self.dataset=ds;self.result=None;self.exportbtn.setEnabled(False)
            self.original.set_data(ds.image_u8,'没有关联的目标/参考图像')
            self.direct.set_data(pixels_q11_to_u8(ds.direct_q11))
            self.board.set_data(None,'尚未执行实际 FPGA 计算')
            self.golden.set_data(pixels_q11_to_u8(ds.golden) if ds.golden is not None else None,
                                 '无独立定点黄金重建向量')
            for m in self.metrics.values():m.update_value('—')
            self.progress.setValue(0)
            d={
                '数据集':ds.label,
                '类型':ds.kind,
                '来源':ds.source_path,
                'Hadamard': 'H4096/64; natural Sylvester / row-major',
                '掩码SHA256':MASK_SHA256,
                '测量数':len(ds.words),
                '测量范围（signed int32 Q11）':[
                    int(np.min(signed_measurements(ds.words))),
                    int(np.max(signed_measurements(ds.words)))],
                '黄金向量':('Stage-0.2 40轮黄金' if ds.golden is not None else '无；无法声明逐像素黄金精确匹配'),
                '来源记录':ds.provenance,
            }
            self.metadata.setPlainText(json.dumps(d,ensure_ascii=False,indent=2))
            self._set_state('测量数据已就绪',True)
            self._append(f'已载入：{ds.label}，1024 点测量；来源={ds.kind}')
            if ds.golden is None:self._append('提示：本组无独立黄金输出；后续仅验证 40 轮硬件执行与协议完整性')
        except Exception as exc:
            QMessageBox.warning(self,'数据无法载入',str(exc))
            self._append(f'载入失败：{exc}')
    def _list_ports(self):
        current=self.port.currentText().strip() or 'COM13'
        try:
            from serial.tools import list_ports
            ports=[p.device for p in list_ports.comports()]
        except ImportError:ports=[]
        self.port.clear()
        for dev in ports:self.port.addItem(dev)
        if current not in ports:self.port.addItem(current)
        self.port.setCurrentText(current)
        self._append('串口扫描：'+(', '.join(ports) if ports else '未列出设备；可手动填写 COM13'))
    def _lock_controls(self,busy:bool):
        for w in [self.source_type,self.preset,self.browse,self.loadbtn,self.port,self.refresh,
                  self.ping,self.runbtn,self.reference_browse,self.confirm,self.acquisition]:
            w.setEnabled(not busy)
        self.cancelbtn.setEnabled(busy)
    def _start(self,mode:str):
        if self.worker and self.worker.isRunning():return
        if mode=='run' and self.dataset is None:
            QMessageBox.warning(self,'缺少数据','请先点击“载入 / 生成测量数据”。');return
        port=self.port.currentText().strip()
        if not port:QMessageBox.warning(self,'缺少端口','请填写串口，例如 COM13。');return
        if mode=='run':
            self.result=None;self.exportbtn.setEnabled(False)
            self.board.set_data(None,'FPGA 计算进行中')
            for m in self.metrics.values():m.update_value('—')
            self._append('开始真实 FPGA 重建；PC 不执行 TV-FISTA 重建算法')
        self.progress.setValue(0)
        self._set_state('正在通信')
        self.phase.setText('建立串口连接…')
        self._lock_controls(True)
        self.worker=Worker(mode,self.dataset,port,1_000_000,self)
        self.worker.progress_changed.connect(self._progress)
        self.worker.completed.connect(self._completed)
        self.worker.failed.connect(self._failed)
        self.worker.stopped.connect(self._stopped)
        self.worker.start()
    def _progress(self,message:str,value:int):
        self.phase.setText(message);self.progress.setValue(value)
        # Avoid a flood of repeated UART query logs while polling.
        if not message.startswith('PL 计算中') or value%8==0:self._append(message)
    def _completed(self,result:dict):
        self._lock_controls(False)
        if result.get('ping'):
            self._set_state('真实硬件连接成功',True)
            self._append(f'PASS: AX7020 UART GET_STATUS = {result["baud"]:,} bps')
            return
        self.result=result
        self.board.set_data(pixels_q11_to_u8(result['pixels']))
        r=result['report']
        self.metrics['match'].update_value(
            f'{r["golden_matched_pixels"]}/4096' if r['golden_available'] else '无黄金基准')
        self.metrics['psnr'].update_value(
            ('∞ dB' if np.isinf(r['psnr_db']) else f'{r["psnr_db"]:.2f} dB')
            if r['psnr_db'] is not None else '无原图')
        self.metrics['core'].update_value(f'{r["core_time_50mhz_s"]:.3f} s')
        self.metrics['cycles'].update_value(f'{r["compute_cycles"]:,}')
        self.metrics['link'].update_value(f'{r["load_time_s"]:.3f} / {r["read_time_s"]:.3f} s')
        self.metrics['total'].update_value(f'{r["total_session_time_s"]:.3f} s')
        if r['golden_available'] and not r['all_pass']:
            self._set_state('结果存在不匹配')
            self._append(f'FAIL: {r["golden_mismatch_count"]} 个像素与黄金向量不符')
        else:
            self._set_state('真实硬件重建完成',True)
            self._append('PASS: 40 轮 FPGA PL 完成，输出 4096 像素')
            if r['golden_available']:
                self._append('PASS: 4096/4096 像素与软件定点黄金结果完全一致')
            else:
                self._append('说明：该输入未提供独立黄金向量，不能据此声明逐像素 bit-exact')
        self.exportbtn.setEnabled(True)
        try:
            target=ROOT/'results'/(
                dt.datetime.now().strftime('%Y%m%d_%H%M%S_')+
                re.sub(r'[^a-zA-Z0-9_-]+','_',self.dataset.label)[:36])
            self._export(target)
            self._append('已自动保存完整实测证据：'+str(target))
        except Exception as exc:
            self._append(f'自动导出失败，请点击导出按钮：{exc}')
        self.tabs.setCurrentIndex(0)
    def _failed(self,message:str):
        self._lock_controls(False);self._set_state('通信或验证失败')
        self.board.set_data(None,'通信或计算失败；没有有效的 FPGA 输出')
        self.phase.setText('失败：'+message)
        self._append('ERROR: '+message)
        QMessageBox.critical(self,'硬件通信失败',message+'\n\n请保留日志；下次运行将先对计算核心执行软复位。')
    def _stopped(self,message:str):
        self._lock_controls(False);self._set_state('已取消');self.phase.setText(message)
        self._append('CANCELLED: '+message)
    def _cancel(self):
        if self.worker and self.worker.isRunning():
            self.worker.stop();self._append('已请求取消；等待当前报文结束')
    def _export(self,target:Path):
        if self.result is None or self.dataset is None:raise ValueError('没有实测数据可导出')
        target.mkdir(parents=True,exist_ok=True)
        d=self.dataset;out=self.result
        report=dict(out['report'])
        report['captured_local_time']=dt.datetime.now().isoformat(timespec='seconds')
        report['mask_sha256']=MASK_SHA256
        report['evidence_origin']='real FPGA UART protocol transaction; NOT XSim and NOT Python reconstruction'
        if report.get('psnr_db') is not None and np.isinf(report['psnr_db']):
            report['psnr_db']='Infinity'
        (target/'fpga_board_report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2,allow_nan=False),encoding='utf-8')
        (target/'fpga_pixels_q11_le.bin').write_bytes(out['raw'])
        write_mem(target/'fpga_pixels_q11_s16.mem',out['pixels'],16)
        write_mem(target/'measurements_q11_s32.mem',d.words,32)
        save_grayscale(target/'direct_backprojection.png',pixels_q11_to_u8(d.direct_q11))
        save_grayscale(target/'fpga_reconstruction.png',pixels_q11_to_u8(out['pixels']))
        if d.image_u8 is not None:save_grayscale(target/'input_or_reference.png',d.image_u8)
        if d.golden is not None:
            save_grayscale(target/'fixedpoint_golden.png',pixels_q11_to_u8(d.golden))
            error=np.abs(np.asarray(out['pixels'],dtype=np.int64)-np.asarray(d.golden,dtype=np.int64))
            save_grayscale(target/'golden_absolute_error_visualization.png',np.clip(error,0,255).reshape(64,64).astype(np.uint8))
        with (target/'metrics.csv').open('w',encoding='utf-8-sig',newline='') as fp:
            w=csv.writer(fp);w.writerow(['metric','value'])
            for key in ['dataset','source_kind','compute_cycles','core_time_50mhz_s','load_time_s',
                'read_time_s','total_session_time_s','golden_matched_pixels','golden_mismatch_count',
                'psnr_db','pixel_min','pixel_max','pixel_sum','output_sha256']:
                w.writerow([key,report.get(key,'')])
        (target/'gui_console_log.txt').write_text(self.log.toPlainText()+'\n',encoding='utf-8')
        (target/'README_证据说明.txt').write_text(
            'Stage-5D 真实 AX7020 FPGA 上板重建结果\n'
            'fpga_reconstruction.png 来自实际 UART 读取的 4096 个 Q5.11 像素。\n'
            'fixedpoint_golden.png 为独立的软件参考输出，不是硬件实测。\n'
            'direct_backprojection.png 为 PC 计算的零填充直接反投影，仅用于对照。\n'
            'core_time_50mhz_s 来自 FPGA 报告的 50 MHz 核心计算周期。\n'
            'total_session_time_s 包含连接和串口协议等额外开销，二者不得混淆。\n'
            '对于外部测量：文件格式一致不证明测量值确实由外部光学实验采集。\n',
            encoding='utf-8')
        import hashlib
        manifest=[]
        for file in sorted(target.iterdir()):
            if file.is_file():
                manifest.append(hashlib.sha256(file.read_bytes()).hexdigest()+'  '+file.name)
        (target/'SHA256SUMS.txt').write_text('\n'.join(manifest)+'\n',encoding='utf-8')
        self.last_export=target
    def _choose_export(self):
        if self.result is None:return
        directory=QFileDialog.getExistingDirectory(self,'选择证据包保存目录',str(ROOT/'results'))
        if not directory:return
        target=Path(directory)/('Stage5D_'+dt.datetime.now().strftime('%Y%m%d_%H%M%S'))
        try:self._export(target)
        except Exception as exc:QMessageBox.critical(self,'导出失败',str(exc));return
        self._append('实验资料已导出：'+str(target))
        QMessageBox.information(self,'导出成功',f'完整实验记录已保存至：\n{target}')
    def closeEvent(self,event):
        if self.worker and self.worker.isRunning():
            QMessageBox.warning(self,'任务进行中','请先取消任务，待 UART 报文结束后再关闭程序。')
            event.ignore()
        else:event.accept()


def main():
    app=QApplication(sys.argv)
    app.setStyle('Fusion')
    app.setStyleSheet(STYLE)
    app.setFont(QFont('Microsoft YaHei',10))
    ui=MainWindow();ui.show()
    sys.exit(app.exec())

if __name__=='__main__':main()
