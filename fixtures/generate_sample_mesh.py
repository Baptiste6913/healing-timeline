"""
generate_sample_mesh.py — Generate an anonymous sample face-like mesh for testing.

Creates a parametric ellipsoid with nose bump, periorbital regions, etc.
Output: OBJ file with vertex colors indicating anatomical zones.
"""

import numpy as np
from pathlib import Path


def generate_head_mesh(
    n_lat: int = 40,
    n_lon: int = 60,
    head_radius: tuple = (0.08, 0.10, 0.09),  # x, y, z in meters
) -> tuple:
    """
    Generate ellipsoid head + nose bump.
    Returns (vertices, faces, zone_weights, normals).
    """
    vertices = []
    normals = []
    zone_weights = []  # 0=none, 1=nasal_tip, 2=dorsum, 3=alar, 4=periorbital, 5=cheek

    rx, ry, rz = head_radius

    for i in range(n_lat + 1):
        theta = np.pi * i / n_lat  # 0 to pi
        for j in range(n_lon):
            phi = 2 * np.pi * j / n_lon  # 0 to 2pi

            # Base ellipsoid
            x = rx * np.sin(theta) * np.cos(phi)
            y = ry * np.sin(theta) * np.sin(phi)
            z = rz * np.cos(theta)

            # Nose bump (front-facing, around theta~pi/2, phi~0)
            nose_center_theta = np.pi / 2
            nose_center_phi = 0.0
            d_theta = theta - nose_center_theta
            d_phi = phi if phi <= np.pi else phi - 2 * np.pi

            # Nose protrusion
            nose_width = 0.3  # radians
            nose_height = 0.5  # radians
            nose_amount = 0.03  # meters
            nose_factor = np.exp(-(d_phi / nose_width)**2 - (d_theta / nose_height)**2)

            # Tip bump (lower part of nose)
            tip_factor = np.exp(-((d_phi) / 0.15)**2 - ((d_theta - 0.15) / 0.15)**2)

            x += (nose_factor * 0.7 + tip_factor * 0.3) * nose_amount * np.cos(phi)

            # Determine zone
            zone = 0
            if tip_factor > 0.5:
                zone = 1  # nasal tip
            elif nose_factor > 0.5 and d_theta < 0:
                zone = 2  # dorsum
            elif nose_factor > 0.3 and abs(d_phi) > 0.1:
                zone = 3  # alar
            elif abs(d_theta + 0.3) < 0.25 and abs(abs(d_phi) - 0.35) < 0.2:
                zone = 4  # periorbital
            elif abs(d_theta) < 0.5 and abs(d_phi) < 0.8 and zone == 0:
                zone = 5  # cheek

            vertices.append([x, y, z])
            zone_weights.append(zone)

            # Normal (approximate: normalized position on ellipsoid)
            nx = x / (rx * rx)
            ny = y / (ry * ry)
            nz = z / (rz * rz)
            length = np.sqrt(nx*nx + ny*ny + nz*nz)
            if length > 0:
                normals.append([nx/length, ny/length, nz/length])
            else:
                normals.append([0, 0, 1])

    # Generate faces (triangles)
    faces = []
    for i in range(n_lat):
        for j in range(n_lon):
            p0 = i * n_lon + j
            p1 = i * n_lon + (j + 1) % n_lon
            p2 = (i + 1) * n_lon + j
            p3 = (i + 1) * n_lon + (j + 1) % n_lon
            faces.append([p0, p2, p1])
            faces.append([p1, p2, p3])

    return np.array(vertices), np.array(faces), np.array(zone_weights), np.array(normals)


def write_obj(filepath: str, vertices: np.ndarray, faces: np.ndarray, normals: np.ndarray):
    """Write mesh to OBJ format."""
    with open(filepath, "w") as f:
        f.write("# Sample face mesh for Healing Timeline Simulation\n")
        f.write("# Generated procedurally — no real patient data\n\n")

        for v in vertices:
            f.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")

        for n in normals:
            f.write(f"vn {n[0]:.6f} {n[1]:.6f} {n[2]:.6f}\n")

        for face in faces:
            f.write(f"f {face[0]+1}//{face[0]+1} {face[1]+1}//{face[1]+1} {face[2]+1}//{face[2]+1}\n")


def write_zone_map(filepath: str, zone_weights: np.ndarray):
    """Write zone assignments as JSON for the iOS app."""
    import json
    zone_names = {0: "none", 1: "nasal_tip", 2: "dorsum", 3: "alar", 4: "periorbital", 5: "cheek"}
    data = {
        "zones": [zone_names[z] for z in zone_weights],
        "weights": {
            "nasal_tip": 1.0,
            "dorsum": 0.7,
            "alar": 0.5,
            "periorbital": 0.4,
            "cheek": 0.2,
            "none": 0.0,
        }
    }
    with open(filepath, "w") as f:
        json.dump(data, f, indent=2)


def main():
    output_dir = Path(__file__).parent
    vertices, faces, zones, normals = generate_head_mesh()

    obj_path = output_dir / "sample_face.obj"
    write_obj(str(obj_path), vertices, faces, normals)
    print(f"[OK] OBJ -> {obj_path} ({len(vertices)} vertices, {len(faces)} faces)")

    zone_path = output_dir / "sample_zones.json"
    write_zone_map(str(zone_path), zones)
    print(f"[OK] Zones -> {zone_path}")

    print(f"\nZone distribution:")
    zone_names = {0: "none", 1: "nasal_tip", 2: "dorsum", 3: "alar", 4: "periorbital", 5: "cheek"}
    for z in range(6):
        count = np.sum(zones == z)
        print(f"  {zone_names[z]:>12}: {count} vertices ({100*count/len(zones):.1f}%)")


if __name__ == "__main__":
    main()
