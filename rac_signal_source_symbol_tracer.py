# !!! Full path to this file should be set up locally on ~/.lldbinit by by adding a line:
# `command script import <full path to this file>

import lldb

def __lldb_init_module(debugger, dict):
  lldb.debugger.HandleCommand("type synthetic add RACPassthroughSubscriber --python-class " + 
      "rac_signal_source_symbol_tracer.RACSignalSourceSymbolTracer")

def evaluateExpressionValue(expression, printErrors = True):
  # lldb.frame is supposed to contain the right frame, but it doesnt :/ so do the dance
  frame = lldb.debugger.GetSelectedTarget().GetProcess().GetSelectedThread().GetSelectedFrame()
  value = frame.EvaluateExpression(expression)
  if printErrors and value.GetError() is not None and str(value.GetError()) != 'success':
    print(value.GetError())
  return value


class RACSignalSourceSymbolTracer:
  SIGNAL_SOURCE_SYMBOL_CHILD_NAME = "signalSourceSymbol"

  def __init__(self, valobj, dict):
    self.valobj = valobj
    self.signalSourceMethodSymbol = self.valobj.CreateValueFromExpression(RACSignalSourceSymbolTracer.SIGNAL_SOURCE_SYMBOL_CHILD_NAME,
      "(NSString *)[%s signalInitializationSourceSymbol]" % self.valobj.GetName())

  def num_children(self):
    return self.valobj.GetNumChildren() + 1

  def get_child_index(self, name):
    if name == RACSignalSourceSymbolTracer.SIGNAL_SOURCE_SYMBOL_CHILD_NAME:
      return 0
    else:
      return self.valobj.GetChildMemberWithName(name) + 1

  def get_child_at_index(self, index):
    if index == 0:
      return self.signalSourceMethodSymbol
    else:
      return self.valobj.GetChildAtIndex(index - 1)

  def update(self):
    pass

  def has_children(self):
    return True
