#!/usr/bin/env python3
"""Require ONNX Runtime to execute a minimal graph through CUDA."""

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper


providers = ort.get_available_providers()
if "CUDAExecutionProvider" not in providers:
    raise RuntimeError(f"CUDAExecutionProvider is unavailable: {providers}")

graph = helper.make_graph(
    [helper.make_node("Identity", ["input"], ["output"])],
    "cuda-smoke",
    [helper.make_tensor_value_info("input", TensorProto.FLOAT, [4])],
    [helper.make_tensor_value_info("output", TensorProto.FLOAT, [4])],
)
model = helper.make_model(
    graph,
    opset_imports=[helper.make_opsetid("", 13)],
    producer_name="immich-in-lxc-cuda-smoke",
)
model.ir_version = 10

options = ort.SessionOptions()
options.add_session_config_entry("session.disable_cpu_ep_fallback", "1")
session = ort.InferenceSession(
    model.SerializeToString(),
    sess_options=options,
    providers=["CUDAExecutionProvider"],
)

expected = np.array([1.0, 2.0, 3.0, 4.0], dtype=np.float32)
actual = session.run(["output"], {"input": expected})[0]
np.testing.assert_array_equal(actual, expected)

print(f"CUDA ONNX inference passed with providers: {session.get_providers()}")
