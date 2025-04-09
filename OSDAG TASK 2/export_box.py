from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.gp import gp_Trsf, gp_Vec
from OCC.Display.SimpleGui import init_display

# Initialize GUI
display, start_display, *_ = init_display()

# Column 1
col1 = BRepPrimAPI_MakeBox(10, 10, 100).Shape()

# Column 2 moved in X-direction
trsf = gp_Trsf()
trsf.SetTranslation(gp_Vec(50, 0, 0))
col2 = BRepBuilderAPI_Transform(BRepPrimAPI_MakeBox(10, 10, 100).Shape(), trsf).Shape()

# Lacing Elements
lacing = []
for z in range(0, 100, 25):
    l_box = BRepPrimAPI_MakeBox(40, 2, 2).Shape()
    move = gp_Trsf()
    move.SetTranslation(gp_Vec(10, 4, z))
    lacing.append(BRepBuilderAPI_Transform(l_box, move).Shape())

# Display
display.DisplayShape(col1, update=True)
display.DisplayShape(col2)
for part in lacing:
    display.DisplayShape(part)

start_display()

