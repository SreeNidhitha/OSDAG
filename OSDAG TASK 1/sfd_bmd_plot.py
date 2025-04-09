import pandas as pd
import matplotlib.pyplot as plt

# Load the Excel file
df = pd.read_excel("SFS_Screening_SFDBMD.xlsx")

# Extract columns
x = df["Distance (m)"]
shear_force = df["SF (kN)"]
bending_moment = df["BM (kN-m)"]

# Create the plots
fig, axs = plt.subplots(1, 2, figsize=(14, 5))

# BMD (left)
axs[0].plot(x, bending_moment, color='red', marker='o')
axs[0].set_title("Bending Moment Diagram")
axs[0].set_xlabel("Distance (m)")
axs[0].set_ylabel("Bending Moment (kN-m)")
axs[0].grid(True)
axs[0].axhline(0, color='black')

# SFD (right)
axs[1].plot(x, shear_force, color='blue', marker='o')
axs[1].set_title("Shear Force Diagram")
axs[1].set_xlabel("Distance (m)")
axs[1].set_ylabel("Shear Force (kN)")
axs[1].grid(True)
axs[1].axhline(0, color='black')

# Save and show
plt.tight_layout()
plt.savefig("SFD_BMD_combined.png")
plt.show()

