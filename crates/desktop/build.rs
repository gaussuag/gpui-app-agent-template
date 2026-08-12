use std::{env, fs, io, path::PathBuf};

use toml::Value;

const ICON_PATH: &str = "resources/windows/app.ico";

#[derive(Debug, PartialEq, Eq)]
struct ProductIdentity {
    product_name: String,
    binary_name: String,
    file_description: String,
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn required_string<'a>(table: &'a toml::Table, key: &str) -> Result<&'a str, io::Error> {
    let value = table
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_data(format!("desktop Cargo.toml is missing string field {key}")))?;
    if value.trim().is_empty()
        || value
            .chars()
            .any(|character| matches!(character, '\r' | '\n' | '\0'))
    {
        return Err(invalid_data(format!(
            "desktop Cargo.toml field {key} must be a non-empty single-line string"
        )));
    }
    Ok(value)
}

fn product_identity(manifest: &str) -> Result<ProductIdentity, io::Error> {
    let document = manifest
        .parse::<Value>()
        .map_err(|error| invalid_data(format!("desktop Cargo.toml is invalid: {error}")))?;
    let package = document
        .get("package")
        .and_then(Value::as_table)
        .ok_or_else(|| invalid_data("desktop Cargo.toml is missing [package]"))?;
    let metadata = package
        .get("metadata")
        .and_then(Value::as_table)
        .and_then(|metadata| metadata.get("winresource"))
        .and_then(Value::as_table)
        .ok_or_else(|| {
            invalid_data("desktop Cargo.toml is missing [package.metadata.winresource]")
        })?;
    let product_name = required_string(metadata, "ProductName")?;
    let original_filename = required_string(metadata, "OriginalFilename")?;
    let file_description = required_string(package, "description")?;

    let binaries = document
        .get("bin")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid_data("desktop Cargo.toml must declare one [[bin]] target"))?;
    if binaries.len() != 1 {
        return Err(invalid_data(format!(
            "desktop Cargo.toml must declare one [[bin]] target, found {}",
            binaries.len()
        )));
    }
    let binary_name = binaries[0]
        .as_table()
        .ok_or_else(|| invalid_data("desktop [[bin]] must be a table"))
        .and_then(|binary| required_string(binary, "name"))?;
    let expected_filename = format!("{binary_name}.exe");
    if original_filename != expected_filename {
        return Err(invalid_data(format!(
            "OriginalFilename must be {expected_filename}, found {original_filename}"
        )));
    }

    Ok(ProductIdentity {
        product_name: product_name.to_owned(),
        binary_name: binary_name.to_owned(),
        file_description: file_description.to_owned(),
    })
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR")?);
    let manifest_path = manifest_dir.join("Cargo.toml");
    let manifest = fs::read_to_string(&manifest_path)?;
    let identity = product_identity(&manifest)?;

    println!("cargo::rerun-if-changed={}", manifest_path.display());
    println!(
        "cargo::rustc-env=PRODUCT_DISPLAY_NAME={}",
        identity.product_name
    );

    let icon_path = manifest_dir.join(ICON_PATH);
    println!("cargo::rerun-if-changed={}", icon_path.display());
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        if !icon_path.is_file() {
            return Err(invalid_data(format!(
                "Windows product icon is missing: {}",
                icon_path.display()
            ))
            .into());
        }
        let icon = icon_path
            .to_str()
            .ok_or_else(|| invalid_data("Windows product icon path is not valid UTF-8"))?;
        let mut resources = winresource::WindowsResource::new();
        resources.set_icon(icon);
        resources.set("FileDescription", &identity.file_description);
        resources.compile()?;
    }

    Ok(())
}
