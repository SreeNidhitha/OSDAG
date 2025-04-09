from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCC.Core.STEPControl import STEPControl_Writer, STEPControl_AsIs
from OCC.Core.IFSelect import IFSelect_RetDone

# Create a simple box
box = BRepPrimAPI_MakeBox(10, 20, 30).Shape()

# Set up STEP writer
step_writer = STEPControl_Writer()
step_writer.Transfer(box, STEPControl_AsIs)
status = step_writer.Write("simple_box.step")

if status == IFSelect_RetDone:
    print("✅ STEP file exported successfully.")
else:
    print("❌ Failed to export STEP file.")
