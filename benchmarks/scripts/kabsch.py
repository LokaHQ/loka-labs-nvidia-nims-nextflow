"""Cα RMSD by Horn quaternion superposition. Pure Python, no numpy here."""
import math, random

def centroid(P):
    n = len(P)
    return [sum(p[i] for p in P)/n for i in range(3)]

def _jacobi(A, iters=100):
    n = 4
    V = [[1.0 if i == j else 0.0 for j in range(n)] for i in range(n)]
    A = [row[:] for row in A]
    for _ in range(iters):
        off = max(((abs(A[i][j]), i, j) for i in range(n) for j in range(i+1, n)))
        if off[0] < 1e-14: break
        _, p, q = off
        theta = (A[q][q] - A[p][p]) / (2*A[p][q])
        t = (1 if theta >= 0 else -1) / (abs(theta) + math.sqrt(theta*theta + 1))
        c = 1/math.sqrt(t*t + 1); s = t*c
        for k in range(n):
            akp, akq = A[k][p], A[k][q]
            A[k][p] = c*akp - s*akq; A[k][q] = s*akp + c*akq
        for k in range(n):
            apk, aqk = A[p][k], A[q][k]
            A[p][k] = c*apk - s*aqk; A[q][k] = s*apk + c*aqk
        for k in range(n):
            vkp, vkq = V[k][p], V[k][q]
            V[k][p] = c*vkp - s*vkq; V[k][q] = s*vkp + c*vkq
    vals = [A[i][i] for i in range(n)]
    return vals, V

def rmsd(P, Q):
    """RMSD after optimal superposition of P onto Q."""
    assert len(P) == len(Q) and len(P) > 2
    cp, cq = centroid(P), centroid(Q)
    P = [[a-b for a, b in zip(p, cp)] for p in P]
    Q = [[a-b for a, b in zip(q, cq)] for q in Q]
    S = [[sum(P[k][i]*Q[k][j] for k in range(len(P))) for j in range(3)] for i in range(3)]
    (Sxx,Sxy,Sxz),(Syx,Syy,Syz),(Szx,Szy,Szz) = S
    N = [
        [Sxx+Syy+Szz, Syz-Szy,      Szx-Sxz,      Sxy-Syx],
        [Syz-Szy,     Sxx-Syy-Szz,  Sxy+Syx,      Szx+Sxz],
        [Szx-Sxz,     Sxy+Syx,     -Sxx+Syy-Szz,  Syz+Szy],
        [Sxy-Syx,     Szx+Sxz,      Syz+Szy,     -Sxx-Syy+Szz],
    ]
    vals, V = _jacobi(N)
    k = max(range(4), key=lambda i: vals[i])
    q = [V[i][k] for i in range(4)]
    w, x, y, z = q
    R = [
        [w*w+x*x-y*y-z*z, 2*(x*y-w*z),     2*(x*z+w*y)],
        [2*(x*y+w*z),     w*w-x*x+y*y-z*z, 2*(y*z-w*x)],
        [2*(x*z-w*y),     2*(y*z+w*x),     w*w-x*x-y*y+z*z],
    ]
    tot = 0.0
    for p, qq in zip(P, Q):
        rp = [sum(R[i][j]*p[j] for j in range(3)) for i in range(3)]
        tot += sum((rp[i]-qq[i])**2 for i in range(3))
    return math.sqrt(tot/len(P))

if __name__ == "__main__":
    random.seed(1)
    A = [[random.uniform(-20, 20) for _ in range(3)] for _ in range(120)]
    print(f"identical                 : {rmsd(A, A):.3f}  (expect 0.000)")
    th = 0.7; c, s = math.cos(th), math.sin(th)
    B = [[c*p[0]-s*p[1]+11.0, s*p[0]+c*p[1]-4.0, p[2]+2.5] for p in A]
    print(f"rigid rotation+translation: {rmsd(A, B):.3f}  (expect 0.000)")
    sigma = 1.0
    C = [[p[i] + random.gauss(0, sigma) for i in range(3)] for p in A]
    print(f"gaussian noise sigma=1.0  : {rmsd(A, C):.3f}  (expect ~{sigma*math.sqrt(3):.2f})")
