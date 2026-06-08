extends Node3D
class_name CalcDisplay

# What is being typed and the answer after '='
@onready var expr_label: Label3D = $Expression 
@onready var result_label: Label3D = $Result 

var expression: String = ""

func input_token(token: String) -> void:
	match token:
		"C":
			expression = ""
			result_label.text = ""
		"←":
			if expression.length() > 0:
				expression = expression.substr(0, expression.length() - 1)
		"=":
			_evaluate()
			return
		_: # Any other digit, operator, decimal, etc
			expression += token
	expr_label.text = expression

func _evaluate() -> void:
	if expression.strip_edges() == "":
		return
	var e := Expression.new()
	if e.parse(expression) != OK:
		result_label.text = "Error"
		return
	var v = e.execute()
	if e.has_execute_failed():
		result_label.text = "Error"
		return
	result_label.text = str(v)
	expression = str(v) # answer becomes the new starting point
	expr_label.text = expression
