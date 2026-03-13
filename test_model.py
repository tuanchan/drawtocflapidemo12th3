# test_model.py
import tensorflow as tf
import numpy as np

# Load model
interpreter = tf.lite.Interpreter(model_path="assets/ml/handwriting.tflite")
interpreter.allocate_tensors()

# Kiểm tra input/output shape
print("Input: - test_model.py:10", interpreter.get_input_details())
print("Output: - test_model.py:11", interpreter.get_output_details())

# Test với input random
input_shape = interpreter.get_input_details()[0]['shape']
print("Input shape: - test_model.py:15", input_shape)

dummy = np.random.rand(*input_shape).astype(np.float32)
interpreter.set_tensor(interpreter.get_input_details()[0]['index'], dummy)
interpreter.invoke()

output = interpreter.get_tensor(interpreter.get_output_details()[0]['index'])
print("Output shape: - test_model.py:22", output.shape)
print("Top 5 indices: - test_model.py:23", output[0].argsort()[-5:][::-1])
print("✅ Model hoạt động bình thường - test_model.py:24")