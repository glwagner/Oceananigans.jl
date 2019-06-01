"""Store previous source terms before updating them."""
function store_previous_source_terms!(grid::RegularCartesianGrid{FT}, Gu::A, Gv::A, Gw::A, GT::A, GS::A, Gpu::A, 
                                      Gpv::A, Gpw::A, GpT::A, 
                                      GpS::A) where {FT, A<:OffsetArray{FT, 3, <:AbstractArray{FT, 3}}}

    @loop for k in (1:grid.Nz; blockIdx().z)
        @loop for j in (1:grid.Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:grid.Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                @inbounds Gpu[i, j, k] = Gu[i, j, k]
                @inbounds Gpv[i, j, k] = Gv[i, j, k]
                @inbounds Gpw[i, j, k] = Gw[i, j, k]
                @inbounds GpT[i, j, k] = GT[i, j, k]
                @inbounds GpS[i, j, k] = GS[i, j, k]
            end
        end
    end
    @synchronize
end

"Store previous value of the source term and calculate current source term."
function calculate_interior_source_terms!(grid::RegularCartesianGrid{FT}, constants::PlanetaryConstants{FT}, 
                                          eos::LinearEquationOfState{FT}, closure::TurbulenceClosure{FT}, 
                                          u::A, v::A, w::A, T::A, S::A, Gu::A, Gv::A, Gw::A, GT::A, 
                                          GS::A, diffusivities, F) where {FT, A<:OffsetArray{FT, 3, <:AbstractArray{FT, 3}}}

    Nx, Ny, Nz = grid.Nx, grid.Ny, grid.Nz
    Δx, Δy, Δz = grid.Δx, grid.Δy, grid.Δz

    grav = constants.g
    fCor = constants.f

    @loop for k in (1:grid.Nz; blockIdx().z)
        @loop for j in (1:grid.Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:grid.Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                # u-momentum equation
                @inbounds Gu[i, j, k] = (-u∇u(grid, u, v, w, i, j, k)
                                            + fv(grid, v, fCor, i, j, k)
                                            + ∂ⱼ_2ν_Σ₁ⱼ(i, j, k, grid, closure, u, v, w, diffusivities)
                                            + F.u(grid, u, v, w, T, S, i, j, k)
                                        )

                # v-momentum equation
                @inbounds Gv[i, j, k] = (-u∇v(grid, u, v, w, i, j, k)
                                            - fu(grid, u, fCor, i, j, k)
                                            + ∂ⱼ_2ν_Σ₂ⱼ(i, j, k, grid, closure, u, v, w, diffusivities)
                                            + F.v(grid, u, v, w, T, S, i, j, k)
                                        )

                # w-momentum equation
                @inbounds Gw[i, j, k] = (-u∇w(grid, u, v, w, i, j, k)
                                         + buoyancy(i, j, k, grid, eos, grav, T, S)
                                         + ∂ⱼ_2ν_Σ₃ⱼ(i, j, k, grid, closure, u, v, w, diffusivities)
                                         + F.w(grid, u, v, w, T, S, i, j, k)
                                        )

                # temperature equation
                @inbounds GT[i, j, k] = (-div_flux(grid, u, v, w, T, i, j, k)
                                         + ∇_κ_∇ϕ(i, j, k, grid, T, closure, diffusivities)
                                         + F.T(grid, u, v, w, T, S, i, j, k)
                                        )

                # salinity equation
                @inbounds GS[i, j, k] = (-div_flux(grid, u, v, w, S, i, j, k)
                                         + ∇_κ_∇ϕ(i, j, k, grid, S, closure, diffusivities)
                                         + F.S(grid, u, v, w, T, S, i, j, k)
                                        )
            end
        end
    end

    @synchronize
end

function adams_bashforth_update_source_terms!(grid::RegularCartesianGrid{FT}, Gu::A, Gv::A, Gw::A, GT::A, GS::A, Gpu::A, Gpv::A, Gpw::A, GpT::A, GpS::A, 
                                              χ::FT) where {FT, A<:OffsetArray{FT, 3, <:AbstractArray{FT, 3}}}
    @loop for k in (1:grid.Nz; blockIdx().z)
        @loop for j in (1:grid.Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:grid.Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                @inbounds Gu[i, j, k] = (FT(1.5) + χ)*Gu[i, j, k] - (FT(0.5) + χ)*Gpu[i, j, k]
                @inbounds Gv[i, j, k] = (FT(1.5) + χ)*Gv[i, j, k] - (FT(0.5) + χ)*Gpv[i, j, k]
                @inbounds Gw[i, j, k] = (FT(1.5) + χ)*Gw[i, j, k] - (FT(0.5) + χ)*Gpw[i, j, k]
                @inbounds GT[i, j, k] = (FT(1.5) + χ)*GT[i, j, k] - (FT(0.5) + χ)*GpT[i, j, k]
                @inbounds GS[i, j, k] = (FT(1.5) + χ)*GS[i, j, k] - (FT(0.5) + χ)*GpS[i, j, k]
            end
        end
    end
    @synchronize
end

"Store previous value of the source term and calculate current source term."
function calculate_poisson_right_hand_side!(::CPU, grid::RegularCartesianGrid{FT}, Δt::TDT, u::A, v::A, w::A, Gu::A, Gv::A, Gw::A, 
                                            RHS) where {TDT, FT, A<:OffsetArray{FT, 3, <:AbstractArray{FT, 3}}}
    @loop for k in (1:grid.Nz; blockIdx().z)
        @loop for j in (1:grid.Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:grid.Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                # Calculate divergence of the RHS source terms (Gu, Gv, Gw).
                @inbounds RHS[i, j, k] = div_f2c(grid, u, v, w, i, j, k) / Δt + div_f2c(grid, Gu, Gv, Gw, i, j, k)
            end
        end
    end

    @synchronize
end

function calculate_poisson_right_hand_side!(::GPU, grid::RegularCartesianGrid{FT}, Δt::FT, u::A, v::A, w::A, 
                                            Gu::A, Gv::A, Gw::A, 
                                            RHS) where {FT, A<:OffsetArray{FT, 3, <:AbstractArray{FT, 3}}}
    Nx, Ny, Nz = grid.Nx, grid.Ny, grid.Nz
    @loop for k in (1:Nz; blockIdx().z)
        @loop for j in (1:Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                # Calculate divergence of the RHS source terms (Gu, Gv, Gw) and applying a permutation
                # which is the first step in the DCT.
                if CUDAnative.ffs(k) == 1  # isodd(k)
                    @inbounds RHS[i, j, convert(UInt32, CUDAnative.floor(k/2) + 1)] = div_f2c(grid, u, v, w, i, j, k) / Δt + div_f2c(grid, Gu, Gv, Gw, i, j, k)
                else
                    @inbounds RHS[i, j, convert(UInt32, Nz - CUDAnative.floor((k-1)/2))] = div_f2c(grid, u, v, w, i, j, k) / Δt + div_f2c(grid, Gu, Gv, Gw, i, j, k)
                end
            end
        end
    end

    @synchronize
end

function idct_permute!(grid::RegularCartesianGrid{FT}, ϕ::A, pNHS::A) where {FT, A<:OffsetArray{FT, 3, <:AbstractArray{FT, 3}}}
    Nx, Ny, Nz = grid.Nx, grid.Ny, grid.Nz
    @loop for k in (1:Nz; blockIdx().z)
        @loop for j in (1:Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                if k <= Nz/2
                    @inbounds pNHS[i, j, 2k-1] = real(ϕ[i, j, k])
                else
                    @inbounds pNHS[i, j, 2(Nz-k+1)] = real(ϕ[i, j, k])
                end
            end
        end
    end

    @synchronize
end


function update_velocities_and_tracers!(grid::RegularCartesianGrid{FT}, u::A, v::A, w::A, T::A, S::A, pNHS::A, Gu::A, Gv::A, Gw::A, GT::A, 
                                        GS::A, Gpu::A, Gpv::A, Gpw::A, GpT::A, GpS::A, Δt::TDT) where {TDT, FT, A<:OffsetArray{FT, 3, <:AbstractArray{FT, 3}}}

    @loop for k in (1:grid.Nz; blockIdx().z)
        @loop for j in (1:grid.Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:grid.Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                @inbounds u[i, j, k] = u[i, j, k] + (Gu[i, j, k] - (δx_c2f(grid, pNHS, i, j, k) / grid.Δx)) * Δt
                @inbounds v[i, j, k] = v[i, j, k] + (Gv[i, j, k] - (δy_c2f(grid, pNHS, i, j, k) / grid.Δy)) * Δt
                @inbounds T[i, j, k] = T[i, j, k] + (GT[i, j, k] * Δt)
                @inbounds S[i, j, k] = S[i, j, k] + (GS[i, j, k] * Δt)
            end
        end
    end

    @synchronize
end

"Compute the vertical velocity w from the continuity equation."
function compute_w_from_continuity!(grid::RegularCartesianGrid{T}, u::A, v::A, w::A) where {T, A<:OffsetArray{T, 3, <:AbstractArray{T, 3}}}
    @loop for j in (1:grid.Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
        @loop for i in (1:grid.Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
            @inbounds w[i, j, 1] = 0
            @unroll for k in 2:grid.Nz
                @inbounds w[i, j, k] = w[i, j, k-1] + grid.Δz * ∇h_u(i, j, k-1, grid, u, v)
            end
        end
    end

    @synchronize
end

"""Store previous source terms before updating them."""
function calculate_diffusivities!(grid::Grid, closure::ConstantSmagorinsky, 
                                  turbdiff, 
                                  eos, grav, u, v, w, T, S) 

    @loop for k in (1:grid.Nz; blockIdx().z)
        @loop for j in (1:grid.Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:grid.Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                @inbounds turbdiff.ν_ccc[i, j, k] = (ν_ccc(i, j, k, grid, closure, eos, grav, u, v, w, T, S) 
                                                     + closure.ν_background)
                @inbounds turbdiff.κ_ccc[i, j, k] = turbdiff.ν_ccc[i, j, k] / closure.Pr + closure.κ_background
            end
        end
    end
    @synchronize
end
