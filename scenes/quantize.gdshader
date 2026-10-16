shader_type canvas_item;

uniform sampler2D screen_texture
    : hint_screen_texture, repeat_disable, filter_nearest;

uniform int kuwahara_radius : hint_range(1, 5, 1) = 3;
uniform float pastel_strength : hint_range(0.0, 1.0) = 1.0;

// Soft pastel palette
const vec3 PALETTE[12] = {
    vec3(0.95, 0.80, 0.80),
    vec3(0.96, 0.86, 0.72),
    vec3(0.98, 0.93, 0.76),
    vec3(0.80, 0.89, 0.75),
    vec3(0.68, 0.85, 0.79),
    vec3(0.70, 0.86, 0.91),
    vec3(0.76, 0.82, 0.94),
    vec3(0.84, 0.77, 0.91),
    vec3(0.92, 0.78, 0.86),
    vec3(0.91, 0.85, 0.82),
    vec3(0.78, 0.76, 0.72),
    vec3(0.96, 0.92, 0.89)
};

vec3 get_screen_color(vec2 uv) {
    return textureLod(screen_texture, uv, 0.0).rgb;
}

void fragment() {
    vec2 uv = SCREEN_UV;
    vec2 pixel = SCREEN_PIXEL_SIZE;
    int r = clamp(kuwahara_radius, 1, 5);

    vec3 mean[4];
    vec3 variance[4];

    for (int q = 0; q < 4; q++) {
        vec3 sum = vec3(0.0);
        vec3 sum_sq = vec3(0.0);
        float count = 0.0;

        for (int x = -5; x <= 5; x++) {
            for (int y = -5; y <= 5; y++) {
                if (abs(x) > r || abs(y) > r) {
                    continue;
                }

                bool use_sample = false;

                if (q == 0) {
                    use_sample = x <= 0 && y <= 0;
                } else if (q == 1) {
                    use_sample = x >= 0 && y <= 0;
                } else if (q == 2) {
                    use_sample = x <= 0 && y >= 0;
                } else {
                    use_sample = x >= 0 && y >= 0;
                }

                if (use_sample) {
                    vec3 c = get_screen_color(
                        uv + vec2(float(x), float(y)) * pixel
                    );

                    sum += c;
                    sum_sq += c * c;
                    count += 1.0;
                }
            }
        }

        mean[q] = sum / count;
        variance[q] = max(
            sum_sq / count - mean[q] * mean[q],
            vec3(0.0)
        );
    }

    // Select the quadrant with the lowest total variance.
    int best = 0;
    float best_var = dot(variance[0], vec3(1.0));

    for (int q = 1; q < 4; q++) {
        float v = dot(variance[q], vec3(1.0));

        if (v < best_var) {
            best_var = v;
            best = q;
        }
    }

    vec3 painted = mean[best];

    // Find the nearest pastel color.
    float min_dist = 1e10;
    vec3 pastel = PALETTE[0];

    for (int i = 0; i < 12; i++) {
        vec3 diff = painted - PALETTE[i];
        float d = dot(diff, diff);

        if (d < min_dist) {
            min_dist = d;
            pastel = PALETTE[i];
        }
    }

    // Apply pastel mapping after painterly smoothing.
    vec3 result = mix(painted, pastel, pastel_strength);

    COLOR = vec4(result, 1.0);
}