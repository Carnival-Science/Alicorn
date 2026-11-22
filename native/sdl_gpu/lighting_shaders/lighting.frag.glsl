#version 450
// Experimental scene-local lighting composite (issue #105). Kept structurally
// identical to lighting.frag.hlsl; see that file for the contract.
layout(set = 2, binding = 0) uniform sampler2D source_texture;

layout(set = 3, binding = 0) uniform LightingUniforms {
    vec4 region;
    vec4 params;
    vec4 surfaces[8];
    vec4 surface_params[8];
    vec4 lights[4];
    vec4 light_colors[4];
} uniforms;

#define SHADOW_STEPS 12
// Contact occlusion is direction independent: it seats a raised surface into
// the paint around it even when the declared light is nearly overhead.
#define CONTACT_RADIUS 16.0
#define CONTACT_STRENGTH 0.26

layout(location = 0) in vec4 input_color;
layout(location = 1) in vec2 input_uv;
layout(location = 0) out vec4 output_color;

float rounded_rect_sdf(vec2 p, vec2 center, vec2 half_extent, float radius) {
    vec2 q = abs(p - center) - (half_extent - vec2(radius));
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

float sdf_at(vec2 p, uint index) {
    return rounded_rect_sdf(p, uniforms.surfaces[index].xy, uniforms.surfaces[index].zw, uniforms.surface_params[index].x);
}

vec2 sdf_gradient(vec2 p, uint index) {
    float epsilon = 0.75;
    float center = sdf_at(p, index);
    float dx = sdf_at(p + vec2(epsilon, 0.0), index) - center;
    float dy = sdf_at(p + vec2(0.0, epsilon), index) - center;
    vec2 gradient = vec2(dx, dy);
    float length_squared = dot(gradient, gradient);
    if (length_squared < 1e-12) { return vec2(0.0); }
    return gradient * inversesqrt(length_squared);
}

float light_visibility(vec3 p, uint self_index, uint light_index, float source_radius) {
    uint surface_count = uint(uniforms.region.z + 0.5);
    vec3 light_position = vec3(uniforms.lights[light_index].xy, uniforms.lights[light_index].z);
    float visible = 1.0;
    for (uint index = 0u; index < surface_count; ++index) {
        if (index == self_index) { continue; }
        if (uniforms.surface_params[index].w <= 0.0) { continue; }
        float top = uniforms.surface_params[index].y;
        if (top <= 0.5) { continue; }
        float nearest = 1e9;
        float nearest_z = 0.0;
        for (int step = 1; step <= SHADOW_STEPS; ++step) {
            float t = float(step) / float(SHADOW_STEPS + 1);
            vec2 q = mix(p.xy, light_position.xy, t);
            float distance_to_surface = sdf_at(q, index);
            if (distance_to_surface < nearest) {
                nearest = distance_to_surface;
                nearest_z = mix(p.z, light_position.z, t);
            }
        }
        if (nearest_z < top && nearest < source_radius) {
            visible = min(visible, clamp(nearest / source_radius, 0.0, 1.0));
        }
    }
    return visible;
}

vec3 shade_point(vec3 p, vec3 normal, uint self_index, bool hard_shadows, bool high_contrast) {
    vec3 sum = vec3(0.0);
    uint light_count = uint(uniforms.params.x + 0.5);
    bool shadows = (uint(uniforms.params.z) & 1u) != 0u;
    for (uint index = 0u; index < light_count; ++index) {
        vec3 light_position = vec3(uniforms.lights[index].xy, uniforms.lights[index].z);
        vec3 to_light = light_position - p;
        float horizontal_squared = dot(to_light.xy, to_light.xy);
        float height = max(light_position.z, 1.0);
        // Soft studio falloff keeps UI-scale illumination broad while
        // retaining a stable, deterministic distance term.
        float attenuation = uniforms.lights[index].w * (4.0 * height * height) / (4.0 * height * height + horizontal_squared);
        vec3 direction = normalize(to_light + vec3(0.0, 0.0, 1e-5));
        float diffuse = max(dot(normal, direction), 0.0);
        float source_radius = hard_shadows ? 0.75 : max(uniforms.light_colors[index].w, 0.75);
        float visible = shadows ? light_visibility(p, self_index, index, source_radius) : 1.0;
        sum += uniforms.light_colors[index].rgb * (attenuation * diffuse * visible);
    }
    if (high_contrast) { sum *= 1.35; }
    return sum;
}

float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    vec4 albedo = texture(source_texture, input_uv);
    vec2 p = gl_FragCoord.xy - uniforms.region.xy;
    uint surface_count = uint(uniforms.region.z + 0.5);
    uint flags = uint(uniforms.params.z + 0.5);
    bool hard_shadows = (flags & 2u) != 0u;
    bool high_contrast = (flags & 4u) != 0u;
    float ambient = uniforms.params.y;

    float best_distance = 1e9;
    float best_height = -1e9;
    float nearest_raised = 1e9;
    int inside = -1;
    for (uint index = 0u; index < surface_count; ++index) {
        float distance_to_surface = sdf_at(p, index);
        float height = uniforms.surface_params[index].y;
        if (distance_to_surface >= 0.0 && uniforms.surface_params[index].w > 0.0) {
            nearest_raised = min(nearest_raised, distance_to_surface);
        }
        if (distance_to_surface < 0.0 && (height > best_height ||
            (height == best_height && distance_to_surface < best_distance))) {
            best_distance = distance_to_surface;
            best_height = height;
            inside = int(index);
        }
    }

    vec3 color = albedo.rgb;
    if (inside >= 0) {
        uint index = uint(inside);
        vec2 gradient = sdf_gradient(p, index);
        float raised = uniforms.surface_params[index].w;
        float bevel = max(uniforms.surface_params[index].z, 0.75);
        float bevel_fraction = clamp(-best_distance / bevel, 0.0, 1.0);
        vec3 normal = normalize(vec3(gradient * (1.0 - bevel_fraction) * raised,
            bevel_fraction + 1e-4));
        vec3 shading_point = vec3(p, best_height + 0.5);
        vec3 direct = shade_point(shading_point, normal, index, hard_shadows, high_contrast);
        vec3 shade = vec3(ambient) + (1.0 - ambient) * direct;
        float modulation = clamp(luminance(shade), 0.5, 1.4);
        // Contact occlusion from other raised slabs only; the selected slab
        // never darkens its own top face.
        float nearest_other = 1e9;
        for (uint other = 0u; other < surface_count; ++other) {
            if (other == index || uniforms.surface_params[other].w <= 0.0) { continue; }
            nearest_other = min(nearest_other, max(sdf_at(p, other), 0.0));
        }
        modulation *= 1.0 - CONTACT_STRENGTH * (1.0 - smoothstep(0.0, CONTACT_RADIUS, nearest_other));
        color = albedo.rgb * modulation;
    } else {
        vec3 direct = shade_point(vec3(p, 0.0), vec3(0.0, 0.0, 1.0), 0xFFFFFFFFu,
            hard_shadows, high_contrast);
        float modulation = 1.0 - uniforms.params.w * clamp(1.0 - luminance(direct), 0.0, 1.0);
        modulation *= 1.0 - CONTACT_STRENGTH * (1.0 - smoothstep(0.0, CONTACT_RADIUS, nearest_raised));
        color = albedo.rgb * modulation;
    }
    output_color = vec4(color, albedo.a);
}
