// Experimental scene-local lighting composite (issue #105).
// One fragment evaluates every declared rounded-slab surface and point light
// directly; there is no height buffer. The captured paint prefix supplies the
// albedo, and lighting only modulates it: text and icons keep their hue and are
// never treated as shadow casters.
Texture2D<float4> source : register(t0, space2);
SamplerState source_sampler : register(s0, space2);

cbuffer LightingUniforms : register(b0, space3) {
    // capture origin in target pixels, surface count, reserved
    float4 g_region;
    // light count, ambient, flags (1 shadows, 2 hard, 4 high contrast), shadow darkness
    float4 g_params;
    // surface center.xy, half extent.xy (region-local pixels)
    float4 g_surfaces[8];
    // corner radius, top z, bevel width, raised(+1)/recessed(-1)
    float4 g_surface_params[8];
    // position.xy, z, intensity
    float4 g_lights[4];
    // color.rgb, source radius in pixels
    float4 g_light_colors[4];
};

#define SHADOW_STEPS 12
// Contact occlusion is direction independent: it seats a raised surface into
// the paint around it even when the declared light is nearly overhead.
#define CONTACT_RADIUS 16.0
#define CONTACT_STRENGTH 0.26

struct Input {
    float4 color : TEXCOORD0;
    float2 uv : TEXCOORD1;
};

float rounded_rect_sdf(float2 p, float2 center, float2 half_extent, float radius) {
    float2 q = abs(p - center) - (half_extent - radius.xx);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float sdf_at(float2 p, uint index) {
    return rounded_rect_sdf(p, g_surfaces[index].xy, g_surfaces[index].zw, g_surface_params[index].x);
}

float2 sdf_gradient(float2 p, uint index) {
    float epsilon = 0.75;
    float center = sdf_at(p, index);
    float dx = sdf_at(p + float2(epsilon, 0.0), index) - center;
    float dy = sdf_at(p + float2(0.0, epsilon), index) - center;
    float2 gradient = float2(dx, dy);
    float length_squared = dot(gradient, gradient);
    if (length_squared < 1e-12) { return float2(0.0, 0.0); }
    return gradient * rsqrt(length_squared);
}

// Returns the visible fraction of one light for a shading point. Raised slabs
// between the point and the light shrink the visible fraction by how deeply the
// light ray passes inside their signed distance, which is the soft penumbra
// driven by the light's source radius.
float light_visibility(float3 p, uint self_index, uint light_index, float source_radius) {
    uint surface_count = uint(g_region.z + 0.5);
    float3 light_position = float3(g_lights[light_index].xy, g_lights[light_index].z);
    float visible = 1.0;
    for (uint index = 0; index < surface_count; ++index) {
        if (index == self_index) { continue; }
        if (g_surface_params[index].w <= 0.0) { continue; }
        float top = g_surface_params[index].y;
        if (top <= 0.5) { continue; }
        float nearest = 1e9;
        float nearest_z = 0.0;
        for (int step = 1; step <= SHADOW_STEPS; ++step) {
            float t = float(step) / float(SHADOW_STEPS + 1);
            float2 q = lerp(p.xy, light_position.xy, t);
            float distance_to_surface = sdf_at(q, index);
            if (distance_to_surface < nearest) {
                nearest = distance_to_surface;
                nearest_z = lerp(p.z, light_position.z, t);
            }
        }
        if (nearest_z < top && nearest < source_radius) {
            visible = min(visible, saturate(nearest / source_radius));
        }
    }
    return visible;
}

float3 shade_point(float3 p, float3 normal, uint self_index, bool hard_shadows, bool high_contrast) {
    float3 sum = float3(0.0, 0.0, 0.0);
    uint light_count = uint(g_params.x + 0.5);
    bool shadows = (uint(g_params.z) & 1u) != 0u;
    for (uint index = 0; index < light_count; ++index) {
        float3 light_position = float3(g_lights[index].xy, g_lights[index].z);
        float3 to_light = light_position - p;
        float horizontal_squared = dot(to_light.xy, to_light.xy);
        float height = max(light_position.z, 1.0);
        // Soft studio falloff keeps UI-scale illumination broad while
        // retaining a stable, deterministic distance term.
        float attenuation = g_lights[index].w * (4.0 * height * height) / (4.0 * height * height + horizontal_squared);
        float3 direction = normalize(to_light + float3(0.0, 0.0, 1e-5));
        float diffuse = max(dot(normal, direction), 0.0);
        float source_radius = hard_shadows ? 0.75 : max(g_light_colors[index].w, 0.75);
        float visible = shadows ? light_visibility(p, self_index, index, source_radius) : 1.0;
        sum += g_light_colors[index].rgb * (attenuation * diffuse * visible);
    }
    if (high_contrast) { sum *= 1.35; }
    return sum;
}

float luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float4 PSMain(Input input, float4 position : SV_POSITION) : SV_Target {
    float4 albedo = source.Sample(source_sampler, input.uv);
    float2 p = position.xy - g_region.xy;
    uint surface_count = uint(g_region.z + 0.5);
    uint flags = uint(g_params.z + 0.5);
    bool hard_shadows = (flags & 2u) != 0u;
    bool high_contrast = (flags & 4u) != 0u;
    float ambient = g_params.y;

    float best_distance = 1e9;
    float best_height = -1e9;
    float nearest_raised = 1e9;
    int inside = -1;
    for (uint index = 0; index < surface_count; ++index) {
        float distance_to_surface = sdf_at(p, index);
        float height = g_surface_params[index].y;
        if (distance_to_surface >= 0.0 && g_surface_params[index].w > 0.0) {
            nearest_raised = min(nearest_raised, distance_to_surface);
        }
        if (distance_to_surface < 0.0 && (height > best_height ||
            (height == best_height && distance_to_surface < best_distance))) {
            best_distance = distance_to_surface;
            best_height = height;
            inside = int(index);
        }
    }

    float3 color = albedo.rgb;
    if (inside >= 0) {
        uint index = uint(inside);
        float2 gradient = sdf_gradient(p, index);
        float raised = g_surface_params[index].w;
        float bevel = max(g_surface_params[index].z, 0.75);
        float bevel_fraction = saturate(-best_distance / bevel);
        float3 normal = normalize(float3(gradient * (1.0 - bevel_fraction) * raised,
            bevel_fraction + 1e-4));
        float3 shading_point = float3(p, best_height + 0.5);
        float3 direct = shade_point(shading_point, normal, index, hard_shadows, high_contrast);
        float3 shade = ambient.xxx + (1.0 - ambient) * direct;
        float modulation = clamp(luminance(shade), 0.5, 1.4);
        // Contact occlusion from other raised slabs only; the selected slab
        // never darkens its own top face.
        float nearest_other = 1e9;
        for (uint other = 0; other < surface_count; ++other) {
            if (other == index || g_surface_params[other].w <= 0.0) { continue; }
            nearest_other = min(nearest_other, max(sdf_at(p, other), 0.0));
        }
        modulation *= 1.0 - CONTACT_STRENGTH * (1.0 - smoothstep(0.0, CONTACT_RADIUS, nearest_other));
        color = albedo.rgb * modulation;
    } else {
        float3 direct = shade_point(float3(p, 0.0), float3(0.0, 0.0, 1.0), 0xFFFFFFFFu,
            hard_shadows, high_contrast);
        float modulation = 1.0 - g_params.w * saturate(1.0 - luminance(direct));
        modulation *= 1.0 - CONTACT_STRENGTH * (1.0 - smoothstep(0.0, CONTACT_RADIUS, nearest_raised));
        color = albedo.rgb * modulation;
    }
    return float4(color, albedo.a);
}
