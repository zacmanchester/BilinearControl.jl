
function simulate_bilinear(F, C, g, x0, z0, U)
    
    x = x0
    z = z0
    Z = [z]
    X = [x]

    for k in 1:length(U)

        u = U[k]
        
        z = F * z + (C * z) .* u
        x = g * z

        push!(Z, z)
        push!(X, x)
        
    end

    return X, Z
end

## Load Reference Trajectory from file
const datadir = joinpath(@__DIR__, "..", "data")
ref_traj = load(joinpath(datadir, "cartpole_reference_trajectory.jld2"))
N = 601  # QUESTION: why not use entire trajectory?
X_ref = ref_traj["X_sim"][1:N]
U_ref = ref_traj["U_sim"][1:N-1]
T_ref = ref_traj["T_sim"][1:N]

## Define model
dt = T_ref[2] - T_ref[1]
tf = T_ref[end]

# Initial condition
x0 = copy(X_ref[1])

# Define the model
model = RobotZoo.Cartpole(1.0, 0.2, 0.5, 9.81)
dmodel = RD.DiscretizedDynamics{RD.RK4}(model)
n,m = RD.dims(model)

## Learn the bilinear dynamics
Z_sim, Zu_sim, kf = BilinearControl.EDMD.build_eigenfunctions(
    X_ref, U_ref, ["state", "sine", "cosine"], [0,0,0]
)
F, C, g = BilinearControl.EDMD.learn_bilinear_model(
    X_ref, Z_sim, Zu_sim, ["lasso", "lasso"]; 
    edmd_weights=[0.0], mapping_weights=[0.0]
)

# Check the koopman transform function
@test all(k->Z_sim[k] ≈ kf(X_ref[k]), eachindex(Z_sim))

## Compare solutions
z0 = kf(x0)
bi_X, bi_Z = simulate_bilinear(F, C, g, x0, z0, U_ref)

# Test that the discrete dynamics match
@test all(1:length(U_ref)) do k
    h = dt
    z = bi_Z[k]
    x = g * bi_Z[k]
    u = U_ref[k]
    xn0 = RD.discrete_dynamics(dmodel, x, U_ref[k], 0, h)
    zn = F*z + C*z * u[1]
    xn_bilinear = g*zn
    norm(xn0 - xn_bilinear) < 5e-2 
end

# Test that the trajectories are similar
@test norm(bi_X - X_ref, Inf) < 0.2

## Load Bilinear Cartpole Model
# model_bilinear = Problems.BilinearCartpole()
model_bilinear = Problems.EDMDModel(F,C,g,kf,dt, "cartpole")
@test RD.discrete_dynamics(model_bilinear, bi_Z[1], U_ref[1], 0.0, dt) ≈ 
    bi_Z[2]

n2,m2 = RD.dims(model_bilinear)
J = zeros(n2, n2+m2)
y = zeros(n2)
z2 = KnotPoint(n2,m2,[bi_Z[1]; U_ref[1]], 0.0, dt)
RD.jacobian!(RD.InPlace(), RD.UserDefined(), model_bilinear, J, y, z2)
@test J ≈ [F+C*U_ref[1][1] C*bi_Z[1]]

Jfd = zero(J)
FiniteDiff.finite_difference_jacobian!(Jfd, 
    (y,x)->RD.discrete_dynamics!(model_bilinear, y, x[1:n2], x[n2+1:end], 0.0, dt),
    z2.z
)
@test Jfd ≈ J

@test BilinearControl.Problems.expandstate(model_bilinear, X_ref[1]) ≈ Z_sim[1]
