package com.demo.upimesh.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Contact;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Swagger UI metadata. Visit /swagger-ui.html once the app is running.
 */
@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI meshPayOpenApi() {
        return new OpenAPI().info(new Info()
                .title("MeshPay — Offline UPI Settlement API")
                .description("Backend for offline UPI payments that propagate through "
                        + "a device mesh and settle once a bridge node reaches the internet. "
                        + "Endpoints under /api/mesh/* are simulator/demo helpers; "
                        + "/api/bridge/ingest is the real production endpoint.")
                .version("v0.1 (MVP)")
                .contact(new Contact().name("Saurav Kumar")));
    }
}
