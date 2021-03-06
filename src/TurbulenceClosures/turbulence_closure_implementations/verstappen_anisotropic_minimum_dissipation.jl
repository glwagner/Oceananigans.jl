"""
    VerstappenAnisotropicMinimumDissipation{FT} <: AbstractAnisotropicMinimumDissipation{FT}

Parameters for the anisotropic minimum dissipation large eddy simulation model proposed by
Verstappen (2018) and described by Vreugdenhil & Taylor (2018).
"""
struct VerstappenAnisotropicMinimumDissipation{FT, K} <: AbstractAnisotropicMinimumDissipation{FT}
     C :: FT
    Cb :: FT
     ν :: FT
     κ :: K

    function VerstappenAnisotropicMinimumDissipation{FT}(C, Cb, ν, κ) where FT
        return new{FT, typeof(κ)}(C, Cb, ν, convert_diffusivity(FT, κ))
    end
end

const VAMD = VerstappenAnisotropicMinimumDissipation

"""
    VerstappenAnisotropicMinimumDissipation(FT=Float64; C=1/12, Cb=0.0, ν=ν₀, κ=κ₀)

Returns parameters of type `FT` for the `VerstappenAnisotropicMinimumDissipation`
turbulence closure.

Keyword arguments
=================
    - `C`  : Poincaré constant
    - `Cb` : Buoyancy modification multiplier (`Cb = 0` turns it off, `Cb = 1` turns it on)
    - `ν`  : Constant background viscosity for momentum
    - `κ`  : Constant background diffusivity for tracer. Can either be a single number
             applied to all tracers, or `NamedTuple` of diffusivities corresponding to each
             tracer.

By default, `C` = 1/12, which is appropriate for a finite-volume method employing a
second-order advection scheme, `Cb` = 0, which terms off the buoyancy modification term,
and molecular values are used for `ν` and `κ`.

References
==========
Vreugdenhil C., and Taylor J. (2018), "Large-eddy simulations of stratified plane Couette
    flow using the anisotropic minimum-dissipation model", Physics of Fluids 30, 085104.

Verstappen, R. (2018), "How much eddy dissipation is needed to counterbalance the nonlinear
    production of small, unresolved scales in a large-eddy simulation of turbulence?",
    Computers & Fluids 176, pp. 276-284.
"""
VerstappenAnisotropicMinimumDissipation(FT=Float64; C=1/12, Cb=0.0, ν=ν₀, κ=κ₀) =
    VerstappenAnisotropicMinimumDissipation{FT}(C, Cb, ν, κ)

function with_tracers(tracers, closure::VerstappenAnisotropicMinimumDissipation{FT}) where FT
    κ = tracer_diffusivities(tracers, closure.κ)
    return VerstappenAnisotropicMinimumDissipation{FT}(closure.C, closure.Cb, closure.ν, κ)
end

#####
##### Constructor
#####

function TurbulentDiffusivities(arch::AbstractArchitecture, grid::AbstractGrid, tracers, ::VAMD)
    νₑ = CellField(arch, grid)
    κₑ = TracerFields(arch, grid, tracers)
    return (νₑ=νₑ, κₑ=κₑ)
end

#####
##### Kernel functions
#####

@inline function νᶜᶜᶜ(i, j, k, grid::AbstractGrid{FT}, closure::VAMD, buoyancy, U, C) where FT
    ijk = (i, j, k, grid)
    q = norm_tr_∇uᶜᶜᶜ(ijk..., U.u, U.v, U.w)

    if q == 0 # SGS viscosity is zero when strain is 0
        νˢᵍˢ = zero(FT)
    else
        r = norm_uᵢₐ_uⱼₐ_Σᵢⱼᶜᶜᶜ(ijk..., closure, U.u, U.v, U.w)
        ζ = norm_wᵢ_bᵢᶜᶜᶜ(ijk..., closure, buoyancy, U.w, C) / Δᶠzᶜᶜᶜ(ijk...)
        δ² = 3 / (1 / Δᶠxᶜᶜᶜ(ijk...)^2 + 1 / Δᶠyᶜᶜᶜ(ijk...)^2 + 1 / Δᶠzᶜᶜᶜ(ijk...)^2)
        νˢᵍˢ = - closure.C * δ² * (r - closure.Cb * ζ) / q
    end

    return max(zero(FT), νˢᵍˢ) + closure.ν
end

@inline function κᶜᶜᶜ(i, j, k, grid::AbstractGrid{FT}, closure::VAMD, c, ::Val{tracer_index},
                       U) where {FT, tracer_index}

    ijk = (i, j, k, grid)
    @inbounds κ = closure.κ[tracer_index]

    σ =  norm_θᵢ²ᶜᶜᶜ(i, j, k, grid, c)

    if σ == 0
        κˢᵍˢ = zero(FT)
    else
        ϑ =  norm_uᵢⱼ_cⱼ_cᵢᶜᶜᶜ(ijk..., closure, U.u, U.v, U.w, c)
        δ² = 3 / (1 / Δᶠxᶜᶜᶜ(ijk...)^2 + 1 / Δᶠyᶜᶜᶜ(ijk...)^2 + 1 / Δᶠzᶜᶜᶜ(ijk...)^2)
        κˢᵍˢ = - closure.C * δ² * ϑ / σ
    end

    return max(zero(FT), κˢᵍˢ) + κ
end

"""
    ∇_κ_∇c(i, j, k, grid, c, tracer_index, closure, diffusivities)

Return the diffusive flux divergence `∇ ⋅ (κ ∇ c)` for the turbulence
`closure`, where `c` is an array of scalar data located at cell centers.
"""
@inline function ∇_κ_∇c(i, j, k, grid, closure::AbstractAnisotropicMinimumDissipation,
                        c, ::Val{tracer_index}, diffusivities, args...) where tracer_index

    κₑ = diffusivities.κₑ[tracer_index]

    return (  ∂xᶜᵃᵃ(i, j, k, grid, κ_∂x_c, κₑ, c, closure)
            + ∂yᵃᶜᵃ(i, j, k, grid, κ_∂y_c, κₑ, c, closure)
            + ∂zᵃᵃᶜ(i, j, k, grid, κ_∂z_c, κₑ, c, closure)
           )
end

function calculate_diffusivities!(K, arch, grid, closure::AbstractAnisotropicMinimumDissipation, buoyancy, U, C)
    @launch(device(arch), config=launch_config(grid, :xyz),
            calculate_viscosity!(K.νₑ, grid, closure, buoyancy, U, C))

    for (tracer_index, κₑ) in enumerate(K.κₑ)
        @inbounds c = C[tracer_index]
        @launch(device(arch), config=launch_config(grid, :xyz),
                calculate_tracer_diffusivity!(κₑ, grid, closure, c, Val(tracer_index), U))
    end

    return nothing
end

function calculate_viscosity!(νₑ, grid, closure::AbstractAnisotropicMinimumDissipation, buoyancy, U, C)
    @loop for k in (1:grid.Nz; (blockIdx().z - 1) * blockDim().z + threadIdx().z)
        @loop for j in (1:grid.Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:grid.Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                @inbounds νₑ[i, j, k] = νᶜᶜᶜ(i, j, k, grid, closure, buoyancy, U, C)
            end
        end
    end
    return nothing
end

function calculate_tracer_diffusivity!(κₑ, grid, closure, c, tracer_index, U)
    @loop for k in (1:grid.Nz; (blockIdx().z - 1) * blockDim().z + threadIdx().z)
        @loop for j in (1:grid.Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:grid.Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                @inbounds κₑ[i, j, k] = κᶜᶜᶜ(i, j, k, grid, closure, c, tracer_index, U)
            end
        end
    end
    return nothing
end

#####
##### Filter width at various locations
#####

# Recall that filter widths are 2x the grid spacing in VAMD
@inline Δᶠxᶜᶜᶜ(i, j, k, grid::RegularCartesianGrid) = 2 * grid.Δx
@inline Δᶠyᶜᶜᶜ(i, j, k, grid::RegularCartesianGrid) = 2 * grid.Δy
@inline Δᶠzᶜᶜᶜ(i, j, k, grid::RegularCartesianGrid) = 2 * grid.Δz

for loc in (:ccf, :fcc, :cfc, :ffc, :cff, :fcf), ξ in (:x, :y, :z)
    Δ_loc = Symbol(:Δᶠ, ξ, :_, loc)
    Δᶜᶜᶜ = Symbol(:Δᶠ, ξ, :ᶜᶜᶜ)
    @eval begin
        const $Δ_loc = $Δᶜᶜᶜ
    end
end

#####
##### The *** 30 terms *** of AMD
#####

@inline function norm_uᵢₐ_uⱼₐ_Σᵢⱼᶜᶜᶜ(i, j, k, grid, closure, u, v, w)
    ijk = (i, j, k, grid)
    uvw = (u, v, w)
    ijkuvw = (i, j, k, grid, u, v, w)

    uᵢ₁_uⱼ₁_Σ₁ⱼ = (
         norm_Σ₁₁(ijkuvw...) * norm_∂x_u(ijk..., u)^2
      +  norm_Σ₂₂(ijkuvw...) * ℑxyᶜᶜᵃ(ijk..., norm_∂x_v², uvw...)
      +  norm_Σ₃₃(ijkuvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂x_w², uvw...)

      +  2 * norm_∂x_u(ijkuvw...) * ℑxyᶜᶜᵃ(ijk..., norm_∂x_v_Σ₁₂, uvw...)
      +  2 * norm_∂x_u(ijkuvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂x_w_Σ₁₃, uvw...)
      +  2 * ℑxyᶜᶜᵃ(ijk..., norm_∂x_v, uvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂x_w, uvw...)
           * ℑyzᵃᶜᶜ(ijk..., norm_Σ₂₃, uvw...)
    )

    uᵢ₂_uⱼ₂_Σ₂ⱼ = (
      + norm_Σ₁₁(ijkuvw...) * ℑxyᶜᶜᵃ(ijk..., norm_∂y_u², uvw...)
      + norm_Σ₂₂(ijkuvw...) * norm_∂y_v(ijk..., v)^2
      + norm_Σ₃₃(ijkuvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂y_w², uvw...)

      +  2 * norm_∂y_v(ijkuvw...) * ℑxyᶜᶜᵃ(ijk..., norm_∂y_u_Σ₁₂, uvw...)
      +  2 * ℑxyᶜᶜᵃ(ijk..., norm_∂y_u, uvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂y_w, uvw...)
           * ℑxzᶜᵃᶜ(ijk..., norm_Σ₁₃, uvw...)
      +  2 * norm_∂y_v(ijkuvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂y_w_Σ₂₃, uvw...)
    )

    uᵢ₃_uⱼ₃_Σ₃ⱼ = (
      + norm_Σ₁₁(ijkuvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂z_u², uvw...)
      + norm_Σ₂₂(ijkuvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂z_v², uvw...)
      + norm_Σ₃₃(ijkuvw...) * norm_∂z_w(ijk..., w)^2

      +  2 * ℑxzᶜᵃᶜ(ijk..., norm_∂z_u, uvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂z_v, uvw...)
           * ℑxyᶜᶜᵃ(ijk..., norm_Σ₁₂, uvw...)
      +  2 * norm_∂z_w(ijkuvw...) * ℑxzᶜᵃᶜ(ijk..., norm_∂z_u_Σ₁₃, uvw...)
      +  2 * norm_∂z_w(ijkuvw...) * ℑyzᵃᶜᶜ(ijk..., norm_∂z_v_Σ₂₃, uvw...)
    )

    return uᵢ₁_uⱼ₁_Σ₁ⱼ + uᵢ₂_uⱼ₂_Σ₂ⱼ + uᵢ₃_uⱼ₃_Σ₃ⱼ
end

#####
##### trace(∇u) = uᵢⱼ uᵢⱼ
#####

@inline function norm_tr_∇uᶜᶜᶜ(i, j, k, grid, uvw...)
    ijk = (i, j, k, grid)

    return (
        # ccc
        norm_∂x_u²(ijk..., uvw...)
      + norm_∂y_v²(ijk..., uvw...)
      + norm_∂z_w²(ijk..., uvw...)

        # ffc
      + ℑxyᶜᶜᵃ(ijk..., norm_∂x_v², uvw...)
      + ℑxyᶜᶜᵃ(ijk..., norm_∂y_u², uvw...)

        # fcf
      + ℑxzᶜᵃᶜ(ijk..., norm_∂x_w², uvw...)
      + ℑxzᶜᵃᶜ(ijk..., norm_∂z_u², uvw...)

        # cff
      + ℑyzᵃᶜᶜ(ijk..., norm_∂y_w², uvw...)
      + ℑyzᵃᶜᶜ(ijk..., norm_∂z_v², uvw...)
    )
end

@inline function norm_wᵢ_bᵢᶜᶜᶜ(i, j, k, grid, closure, buoyancy, w, C)
    ijk = (i, j, k, grid)

    wx_bx = (ℑxzᶜᵃᶜ(ijk..., norm_∂x_w, w)
             * Δᶠxᶜᶜᶜ(ijk...) * ℑxᶜᵃᵃ(ijk..., ∂xᶠᵃᵃ, buoyancy_perturbation, buoyancy, C))

    wy_by = (ℑyzᵃᶜᶜ(ijk..., norm_∂y_w, w)
             * Δᶠyᶜᶜᶜ(ijk...) * ℑyᵃᶜᵃ(ijk..., ∂yᵃᶠᵃ, buoyancy_perturbation, buoyancy, C))

    wz_bz = (norm_∂z_w(ijk..., w)
             * Δᶠzᶜᶜᶜ(ijk...) * ℑzᵃᵃᶜ(ijk..., ∂zᵃᵃᶠ, buoyancy_perturbation, buoyancy, C))

    return wx_bx + wy_by + wz_bz
end

@inline function norm_uᵢⱼ_cⱼ_cᵢᶜᶜᶜ(i, j, k, grid, closure, u, v, w, c)
    ijk = (i, j, k, grid)

    cx_ux = (
                  norm_∂x_u(ijk..., u) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c², c)
        + ℑxyᶜᶜᵃ(ijk..., norm_∂x_v, v) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c, c) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c, c)
        + ℑxzᶜᵃᶜ(ijk..., norm_∂x_w, w) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c, c) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c, c)
    )

    cy_uy = (
          ℑxyᶜᶜᵃ(ijk..., norm_∂y_u, u) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c, c) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c, c)
        +         norm_∂y_v(ijk..., v) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c², c)
        + ℑxzᶜᵃᶜ(ijk..., norm_∂y_w, w) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c, c) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c, c)
    )

    cz_uz = (
          ℑxzᶜᵃᶜ(ijk..., norm_∂z_u, u) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c, c) * ℑxᶜᵃᵃ(ijk..., norm_∂x_c, c)
        + ℑyzᵃᶜᶜ(ijk..., norm_∂z_v, v) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c, c) * ℑyᵃᶜᵃ(ijk..., norm_∂y_c, c)
        +         norm_∂z_w(ijk..., w) * ℑzᵃᵃᶜ(ijk..., norm_∂z_c², c)
    )

    return cx_ux + cy_uy + cz_uz
end

@inline norm_θᵢ²ᶜᶜᶜ(i, j, k, grid, c) = (
      ℑxᶜᵃᵃ(i, j, k, grid, norm_∂x_c², c)
    + ℑyᵃᶜᵃ(i, j, k, grid, norm_∂y_c², c)
    + ℑzᵃᵃᶜ(i, j, k, grid, norm_∂z_c², c)
)
